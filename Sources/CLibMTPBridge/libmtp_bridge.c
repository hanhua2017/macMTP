#include "libmtp_bridge.h"

#include <libmtp.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

struct mtp_bridge_handle {
    LIBMTP_mtpdevice_t *device;
    char last_error[1024];
    pthread_mutex_t mutex;
    int destroyed;
};

static void mtp_bridge_set_error(mtp_bridge_handle_t *handle, const char *message) {
    if (handle == NULL) {
        return;
    }
    if (message == NULL) {
        handle->last_error[0] = '\0';
        return;
    }
    snprintf(handle->last_error, sizeof(handle->last_error), "%s", message);
}

static void mtp_bridge_set_error_from_errorstack(mtp_bridge_handle_t *handle, const char *fallback) {
    char message[sizeof(handle->last_error)];
    size_t used = 0;
    LIBMTP_error_t *error = LIBMTP_Get_Errorstack(handle->device);

    message[0] = '\0';
    for (; error != NULL; error = error->next) {
        if (error->error_text == NULL || error->error_text[0] == '\0') {
            continue;
        }

        int written = snprintf(
            message + used,
            sizeof(message) - used,
            "%s%s",
            used == 0 ? "" : "; ",
            error->error_text);
        if (written < 0) {
            break;
        }
        if ((size_t)written >= sizeof(message) - used) {
            used = sizeof(message) - 1;
            break;
        }
        used += (size_t)written;
    }

    mtp_bridge_set_error(handle, used == 0 ? fallback : message);
    LIBMTP_Clear_Errorstack(handle->device);
}

static char *mtp_bridge_strdup_or_empty(const char *value) {
    return strdup(value == NULL ? "" : value);
}

static char *mtp_bridge_json_escape(const char *value) {
    const unsigned char *src = (const unsigned char *)(value == NULL ? "" : value);
    size_t extra = 0;
    for (const unsigned char *p = src; *p; p++) {
        if (*p == '"' || *p == '\\' || *p == '\b' || *p == '\f' || *p == '\n' || *p == '\r' || *p == '\t') {
            extra++;
        } else if (*p < 0x20) {
            extra += 5;
        }
    }

    size_t len = strlen((const char *)src);
    char *out = malloc(len + extra + 1);
    if (out == NULL) {
        return NULL;
    }

    char *w = out;
    for (const unsigned char *p = src; *p; p++) {
        switch (*p) {
            case '"':
                *w++ = '\\';
                *w++ = '"';
                break;
            case '\\':
                *w++ = '\\';
                *w++ = '\\';
                break;
            case '\b':
                *w++ = '\\';
                *w++ = 'b';
                break;
            case '\f':
                *w++ = '\\';
                *w++ = 'f';
                break;
            case '\n':
                *w++ = '\\';
                *w++ = 'n';
                break;
            case '\r':
                *w++ = '\\';
                *w++ = 'r';
                break;
            case '\t':
                *w++ = '\\';
                *w++ = 't';
                break;
            default:
                if (*p < 0x20) {
                    snprintf(w, 7, "\\u%04x", *p);
                    w += 6;
                } else {
                    *w++ = (char)*p;
                }
                break;
        }
    }
    *w = '\0';
    return out;
}

static char *mtp_bridge_format_alloc(const char *format, ...) {
    va_list args;
    va_start(args, format);
    va_list copy;
    va_copy(copy, args);
    int needed = vsnprintf(NULL, 0, format, copy);
    va_end(copy);
    if (needed < 0) {
        va_end(args);
        return NULL;
    }

    char *buffer = malloc((size_t)needed + 1);
    if (buffer == NULL) {
        va_end(args);
        return NULL;
    }
    vsnprintf(buffer, (size_t)needed + 1, format, args);
    va_end(args);
    return buffer;
}

static uint32_t mtp_bridge_root_parent_for_path(const char *path) {
    (void)path;
    return LIBMTP_FILES_AND_FOLDERS_ROOT;
}

static int mtp_bridge_split_path(const char *path, char ***parts_out, size_t *count_out) {
    *parts_out = NULL;
    *count_out = 0;
    if (path == NULL || strcmp(path, "/") == 0 || strlen(path) == 0) {
        return 0;
    }

    char *copy = strdup(path);
    if (copy == NULL) {
        return -1;
    }
    size_t capacity = 8;
    char **parts = calloc(capacity, sizeof(char *));
    if (parts == NULL) {
        free(copy);
        return -1;
    }

    char *save = NULL;
    char *token = strtok_r(copy, "/", &save);
    while (token != NULL) {
        if (*count_out == capacity) {
            capacity *= 2;
            char **next = realloc(parts, capacity * sizeof(char *));
            if (next == NULL) {
                for (size_t i = 0; i < *count_out; i++) {
                    free(parts[i]);
                }
                free(parts);
                free(copy);
                return -1;
            }
            parts = next;
        }
        parts[*count_out] = strdup(token);
        if (parts[*count_out] == NULL) {
            for (size_t i = 0; i < *count_out; i++) {
                free(parts[i]);
            }
            free(parts);
            free(copy);
            return -1;
        }
        (*count_out)++;
        token = strtok_r(NULL, "/", &save);
    }
    free(copy);
    *parts_out = parts;
    return 0;
}

static void mtp_bridge_free_parts(char **parts, size_t count) {
    if (parts == NULL) {
        return;
    }
    for (size_t i = 0; i < count; i++) {
        free(parts[i]);
    }
    free(parts);
}

static void mtp_bridge_destroy_file_list(LIBMTP_file_t *files) {
    while (files != NULL) {
        LIBMTP_file_t *next = files->next;
        files->next = NULL;
        LIBMTP_destroy_file_t(files);
        files = next;
    }
}

static void mtp_bridge_destroy_track_list(LIBMTP_track_t *tracks) {
    while (tracks != NULL) {
        LIBMTP_track_t *next = tracks->next;
        tracks->next = NULL;
        mtp_bridge_destroy_track_list(tracks);
        tracks = next;
    }
}

static void mtp_bridge_destroy_playlist_list(LIBMTP_playlist_t *playlists) {
    while (playlists != NULL) {
        LIBMTP_playlist_t *next = playlists->next;
        playlists->next = NULL;
        mtp_bridge_destroy_playlist_list(playlists);
        playlists = next;
    }
}

static void mtp_bridge_destroy_album_list(LIBMTP_album_t *albums) {
    while (albums != NULL) {
        LIBMTP_album_t *next = albums->next;
        albums->next = NULL;
        mtp_bridge_destroy_album_list(albums);
        albums = next;
    }
}

static int mtp_bridge_set_error_from_errorstack_if_present(mtp_bridge_handle_t *handle, const char *fallback) {
    LIBMTP_error_t *error = LIBMTP_Get_Errorstack(handle->device);
    if (error == NULL) {
        return 0;
    }
    mtp_bridge_set_error_from_errorstack(handle, fallback);
    return 1;
}

static int mtp_bridge_resolve_object_id_locked(
    mtp_bridge_handle_t *handle,
    uint32_t storage_id,
    const char *path,
    uint32_t *object_id,
    int *is_folder) {
    char **parts = NULL;
    size_t count = 0;
    uint32_t parent_id = mtp_bridge_root_parent_for_path(path);

    if (mtp_bridge_split_path(path, &parts, &count) != 0) {
        mtp_bridge_set_error(handle, "Failed to allocate MTP path components");
        return -1;
    }
    if (count == 0) {
        *object_id = parent_id;
        if (is_folder != NULL) {
            *is_folder = 1;
        }
        return 0;
    }

    for (size_t index = 0; index < count; index++) {
        LIBMTP_Clear_Errorstack(handle->device);
        LIBMTP_file_t *files = LIBMTP_Get_Files_And_Folders(handle->device, storage_id, parent_id);
        if (files == NULL) {
            if (!mtp_bridge_set_error_from_errorstack_if_present(handle, "Failed to read MTP directory")) {
                mtp_bridge_set_error(handle, "MTP path was not found");
            }
            mtp_bridge_free_parts(parts, count);
            return -1;
        }

        LIBMTP_file_t *match = NULL;
        for (LIBMTP_file_t *file = files; file != NULL; file = file->next) {
            if (file->filename != NULL && strcmp(file->filename, parts[index]) == 0) {
                match = file;
                break;
            }
        }
        if (match == NULL) {
            mtp_bridge_destroy_file_list(files);
            mtp_bridge_free_parts(parts, count);
            mtp_bridge_set_error(handle, "MTP path was not found");
            return -1;
        }
        if (index + 1 < count && match->filetype != LIBMTP_FILETYPE_FOLDER) {
            mtp_bridge_destroy_file_list(files);
            mtp_bridge_free_parts(parts, count);
            mtp_bridge_set_error(handle, "An MTP path component is not a folder");
            return -1;
        }

        parent_id = match->item_id;
        if (index + 1 == count && is_folder != NULL) {
            *is_folder = match->filetype == LIBMTP_FILETYPE_FOLDER;
        }
        mtp_bridge_destroy_file_list(files);
    }

    mtp_bridge_free_parts(parts, count);
    *object_id = parent_id;
    return 0;
}

int mtp_bridge_resolve_object_id(
    mtp_bridge_handle_t *handle,
    uint32_t storage_id,
    const char *path,
    uint32_t *object_id,
    int *is_folder) {
    if (handle == NULL || object_id == NULL) {
        return -1;
    }

    pthread_mutex_lock(&handle->mutex);
    if (handle->destroyed) {
        mtp_bridge_set_error(handle, "libmtp bridge handle is destroyed");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    if (handle->device == NULL) {
        mtp_bridge_set_error(handle, "Device is not connected");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }

    int result = mtp_bridge_resolve_object_id_locked(handle, storage_id, path, object_id, is_folder);
    if (result == 0) {
        mtp_bridge_set_error(handle, "");
    }
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

typedef struct {
    char *data;
    size_t length;
    size_t capacity;
} mtp_bridge_json_builder_t;

static int mtp_bridge_json_builder_init(mtp_bridge_json_builder_t *builder, const char *initial) {
    builder->length = strlen(initial);
    builder->capacity = builder->length + 1;
    builder->data = strdup(initial);
    return builder->data == NULL ? -1 : 0;
}

static void mtp_bridge_json_builder_destroy(mtp_bridge_json_builder_t *builder) {
    free(builder->data);
    builder->data = NULL;
    builder->length = 0;
    builder->capacity = 0;
}

static int mtp_bridge_json_builder_append(mtp_bridge_json_builder_t *builder, const char *value) {
    size_t value_length = strlen(value);
    if (value_length > SIZE_MAX - builder->length - 1) {
        return -1;
    }
    size_t required = builder->length + value_length + 1;
    if (required > builder->capacity) {
        size_t capacity = builder->capacity;
        while (capacity < required) {
            if (capacity > SIZE_MAX / 2) {
                capacity = required;
                break;
            }
            capacity *= 2;
        }
        char *next = realloc(builder->data, capacity);
        if (next == NULL) {
            return -1;
        }
        builder->data = next;
        builder->capacity = capacity;
    }
    memcpy(builder->data + builder->length, value, value_length + 1);
    builder->length += value_length;
    return 0;
}

static char *mtp_bridge_join_path(const char *parent_path, const char *name) {
    const char *safe_name = name == NULL ? "" : name;
    if (parent_path == NULL || parent_path[0] == '\0' || strcmp(parent_path, "/") == 0) {
        return mtp_bridge_format_alloc("/%s", safe_name);
    }

    size_t parent_length = strlen(parent_path);
    while (parent_length > 1 && parent_path[parent_length - 1] == '/') {
        parent_length--;
    }
    return mtp_bridge_format_alloc("%.*s/%s", (int)parent_length, parent_path, safe_name);
}

static char *mtp_bridge_file_extension(const char *name) {
    const char *safe_name = name == NULL ? "" : name;
    const char *extension = strrchr(safe_name, '.');
    if (extension == NULL || extension == safe_name || extension[1] == '\0') {
        return strdup("");
    }
    return strdup(extension + 1);
}

static int mtp_bridge_format_date(time_t value, char output[25]) {
    struct tm utc;
    if (gmtime_r(&value, &utc) == NULL) {
        return -1;
    }
    return strftime(output, 25, "%Y-%m-%dT%H:%M:%S.000Z", &utc) == 24 ? 0 : -1;
}

static int mtp_bridge_append_directory_entries(
    mtp_bridge_handle_t *handle,
    uint32_t storage_id,
    uint32_t parent_id,
    const char *parent_path,
    int recursive,
    mtp_bridge_json_builder_t *builder,
    int *first) {
    LIBMTP_Clear_Errorstack(handle->device);
    LIBMTP_file_t *files = LIBMTP_Get_Files_And_Folders(handle->device, storage_id, parent_id);
    if (files == NULL) {
        return mtp_bridge_set_error_from_errorstack_if_present(handle, "Failed to read MTP directory") ? -1 : 0;
    }

    for (LIBMTP_file_t *file = files; file != NULL; file = file->next) {
        char date_added[25];
        char *path = mtp_bridge_join_path(parent_path, file->filename);
        char *extension = mtp_bridge_file_extension(file->filename);
        char *escaped_name = mtp_bridge_json_escape(file->filename);
        char *escaped_path = mtp_bridge_json_escape(path);
        char *escaped_parent_path = mtp_bridge_json_escape(parent_path);
        char *escaped_extension = mtp_bridge_json_escape(extension);
        int is_folder = file->filetype == LIBMTP_FILETYPE_FOLDER;

        if (mtp_bridge_format_date(file->modificationdate, date_added) != 0 || path == NULL || extension == NULL
            || escaped_name == NULL || escaped_path == NULL || escaped_parent_path == NULL || escaped_extension == NULL) {
            free(path);
            free(extension);
            free(escaped_name);
            free(escaped_path);
            free(escaped_parent_path);
            free(escaped_extension);
            mtp_bridge_destroy_file_list(files);
            mtp_bridge_set_error(handle, "Failed to allocate MTP directory JSON");
            return -1;
        }

        char *entry = mtp_bridge_format_alloc(
            "%s{\"size\":%llu,\"isFolder\":%s,\"dateAdded\":\"%s\",\"name\":\"%s\",\"path\":\"%s\",\"parentPath\":\"%s\",\"extension\":\"%s\",\"parentId\":%u,\"objectId\":%u}",
            *first ? "" : ",",
            (unsigned long long)file->filesize,
            is_folder ? "true" : "false",
            date_added,
            escaped_name,
            escaped_path,
            escaped_parent_path,
            escaped_extension,
            file->parent_id,
            file->item_id);
        free(extension);
        free(escaped_name);
        free(escaped_path);
        free(escaped_parent_path);
        free(escaped_extension);

        if (entry == NULL || mtp_bridge_json_builder_append(builder, entry) != 0) {
            free(entry);
            free(path);
            mtp_bridge_destroy_file_list(files);
            mtp_bridge_set_error(handle, "Failed to allocate MTP directory JSON");
            return -1;
        }
        free(entry);
        *first = 0;

        if (recursive && is_folder
            && mtp_bridge_append_directory_entries(handle, storage_id, file->item_id, path, recursive, builder, first) != 0) {
            free(path);
            mtp_bridge_destroy_file_list(files);
            return -1;
        }
        free(path);
    }

    mtp_bridge_destroy_file_list(files);
    return 0;
}

mtp_bridge_handle_t *mtp_bridge_create(void) {
    LIBMTP_Init();
    mtp_bridge_handle_t *handle = calloc(1, sizeof(mtp_bridge_handle_t));
    if (handle == NULL) {
        return NULL;
    }
    if (pthread_mutex_init(&handle->mutex, NULL) != 0) {
        free(handle);
        return NULL;
    }
    handle->device = NULL;
    handle->last_error[0] = '\0';
    handle->destroyed = 0;
    return handle;
}

void mtp_bridge_destroy(mtp_bridge_handle_t *handle) {
    if (handle == NULL) {
        return;
    }
    pthread_mutex_lock(&handle->mutex);
    if (!handle->destroyed && handle->device != NULL) {
        LIBMTP_Release_Device(handle->device);
        handle->device = NULL;
    }
    handle->destroyed = 1;
    mtp_bridge_set_error(handle, "libmtp bridge handle is destroyed");
    pthread_mutex_unlock(&handle->mutex);

    /*
     * C ABI lifecycle protection: close the underlying MTP resource but retain
     * this small handle and mutex so concurrent callers and last_error pointers
     * cannot observe freed storage. Swift owns a singleton handle, so this is a
     * one-time small-object leak for the process lifetime.
     */
}

const char *mtp_bridge_last_error(mtp_bridge_handle_t *handle) {
    if (handle == NULL) {
        return "libmtp bridge handle is null";
    }
    pthread_mutex_lock(&handle->mutex);
    const char *last_error = handle->last_error;
    pthread_mutex_unlock(&handle->mutex);
    return last_error;
}

void mtp_bridge_free_string(char *value) {
    free(value);
}

int mtp_bridge_connect(mtp_bridge_handle_t *handle) {
    if (handle == NULL) {
        return -1;
    }
    pthread_mutex_lock(&handle->mutex);
    if (handle->destroyed) {
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    if (handle->device != NULL) {
        pthread_mutex_unlock(&handle->mutex);
        return 0;
    }

    LIBMTP_raw_device_t *rawdevices = NULL;
    int numrawdevices = 0;
    LIBMTP_error_number_t err = LIBMTP_Detect_Raw_Devices(&rawdevices, &numrawdevices);
    if (err == LIBMTP_ERROR_NO_DEVICE_ATTACHED || numrawdevices == 0) {
        mtp_bridge_set_error(handle, "No MTP device attached");
        if (rawdevices != NULL) {
            LIBMTP_FreeMemory(rawdevices);
        }
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    if (err != LIBMTP_ERROR_NONE || rawdevices == NULL) {
        mtp_bridge_set_error(handle, "Failed to detect MTP devices");
        if (rawdevices != NULL) {
            LIBMTP_FreeMemory(rawdevices);
        }
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }

    handle->device = LIBMTP_Open_Raw_Device_Uncached(&rawdevices[0]);
    LIBMTP_FreeMemory(rawdevices);
    if (handle->device == NULL) {
        mtp_bridge_set_error(handle, "Failed to open MTP device");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }

    mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return 0;
}

void mtp_bridge_disconnect(mtp_bridge_handle_t *handle) {
    if (handle == NULL) {
        return;
    }
    pthread_mutex_lock(&handle->mutex);
    if (handle->destroyed) {
        pthread_mutex_unlock(&handle->mutex);
        return;
    }
    if (handle->device != NULL) {
        LIBMTP_Release_Device(handle->device);
        handle->device = NULL;
    }
    mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
}

char *mtp_bridge_device_info_json(mtp_bridge_handle_t *handle) {
    if (handle == NULL) {
        return NULL;
    }
    pthread_mutex_lock(&handle->mutex);
    if (handle->destroyed) {
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    if (handle->device == NULL) {
        mtp_bridge_set_error(handle, "Device is not connected");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }

    char *manufacturer_raw = LIBMTP_Get_Manufacturername(handle->device);
    char *model_raw = LIBMTP_Get_Modelname(handle->device);
    char *serial_raw = LIBMTP_Get_Serialnumber(handle->device);
    char *version_raw = LIBMTP_Get_Deviceversion(handle->device);
    char *manufacturer = mtp_bridge_json_escape(manufacturer_raw);
    char *model = mtp_bridge_json_escape(model_raw);
    char *serial = mtp_bridge_json_escape(serial_raw);
    char *version = mtp_bridge_json_escape(version_raw);

    if (manufacturer == NULL || model == NULL || serial == NULL || version == NULL) {
        if (manufacturer_raw != NULL) {
            LIBMTP_FreeMemory(manufacturer_raw);
        }
        if (model_raw != NULL) {
            LIBMTP_FreeMemory(model_raw);
        }
        if (serial_raw != NULL) {
            LIBMTP_FreeMemory(serial_raw);
        }
        if (version_raw != NULL) {
            LIBMTP_FreeMemory(version_raw);
        }
        free(manufacturer);
        free(model);
        free(serial);
        free(version);
        mtp_bridge_set_error(handle, "Failed to allocate device information JSON");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }

    char *json = mtp_bridge_format_alloc(
        "{\"error\":null,\"data\":{\"mtpDeviceInfo\":{\"Manufacturer\":\"%s\",\"Model\":\"%s\",\"DeviceVersion\":\"%s\",\"SerialNumber\":\"%s\",\"StandardVersion\":null,\"MTPVendorExtensionID\":null,\"MTPVersion\":null,\"MTPExtension\":null,\"FunctionalMode\":null},\"usbDeviceInfo\":null}}",
        manufacturer == NULL ? "" : manufacturer,
        model == NULL ? "" : model,
        version == NULL ? "" : version,
        serial == NULL ? "" : serial);

    if (manufacturer_raw != NULL) {
        LIBMTP_FreeMemory(manufacturer_raw);
    }
    if (model_raw != NULL) {
        LIBMTP_FreeMemory(model_raw);
    }
    if (serial_raw != NULL) {
        LIBMTP_FreeMemory(serial_raw);
    }
    if (version_raw != NULL) {
        LIBMTP_FreeMemory(version_raw);
    }
    free(manufacturer);
    free(model);
    free(serial);
    free(version);

    if (json == NULL) {
        mtp_bridge_set_error(handle, "Failed to allocate device information JSON");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return json;
}

char *mtp_bridge_storages_json(mtp_bridge_handle_t *handle) {
    if (handle == NULL) {
        return NULL;
    }
    pthread_mutex_lock(&handle->mutex);
    if (handle->destroyed) {
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    if (handle->device == NULL) {
        mtp_bridge_set_error(handle, "Device is not connected");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    if (LIBMTP_Get_Storage(handle->device, LIBMTP_STORAGE_SORTBY_NOTSORTED) < 0) {
        mtp_bridge_set_error_from_errorstack(handle, "Failed to read MTP storage list");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }

    char *json = mtp_bridge_strdup_or_empty("{\"error\":null,\"data\":[");
    if (json == NULL) {
        mtp_bridge_set_error(handle, "Failed to allocate storage list JSON");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }

    size_t json_len = strlen(json);
    int first = 1;
    for (LIBMTP_devicestorage_t *storage = handle->device->storage; storage != NULL; storage = storage->next) {
        uint32_t free_space_in_images = storage->FreeSpaceInObjects == UINT64_MAX
            ? 0
            : storage->FreeSpaceInObjects > UINT32_MAX
                ? UINT32_MAX
                : (uint32_t)storage->FreeSpaceInObjects;
        char *description = mtp_bridge_json_escape(storage->StorageDescription);
        char *volume = mtp_bridge_json_escape(storage->VolumeIdentifier);
        if (description == NULL || volume == NULL) {
            free(description);
            free(volume);
            free(json);
            mtp_bridge_set_error(handle, "Failed to allocate storage list JSON");
            pthread_mutex_unlock(&handle->mutex);
            return NULL;
        }
        char *entry = mtp_bridge_format_alloc(
            "%s{\"Sid\":%u,\"Info\":{\"StorageType\":%u,\"FilesystemType\":%u,\"AccessCapability\":%u,\"MaxCapability\":%llu,\"FreeSpaceInBytes\":%llu,\"FreeSpaceInImages\":%u,\"StorageDescription\":\"%s\",\"VolumeLabel\":\"%s\"}}",
            first ? "" : ",",
            storage->id,
            storage->StorageType,
            storage->FilesystemType,
            storage->AccessCapability,
            (unsigned long long)storage->MaxCapacity,
            (unsigned long long)storage->FreeSpaceInBytes,
            free_space_in_images,
            description,
            volume);
        free(description);
        free(volume);

        if (entry == NULL) {
            free(json);
            mtp_bridge_set_error(handle, "Failed to allocate storage list JSON");
            pthread_mutex_unlock(&handle->mutex);
            return NULL;
        }

        size_t entry_len = strlen(entry);
        char *next = realloc(json, json_len + entry_len + 1);
        if (next == NULL) {
            free(json);
            free(entry);
            mtp_bridge_set_error(handle, "Failed to allocate storage list JSON");
            pthread_mutex_unlock(&handle->mutex);
            return NULL;
        }
        json = next;
        memcpy(json + json_len, entry, entry_len + 1);
        json_len += entry_len;
        free(entry);
        first = 0;
    }

    char *next = realloc(json, json_len + 3);
    if (next == NULL) {
        free(json);
        mtp_bridge_set_error(handle, "Failed to allocate storage list JSON");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    json = next;
    memcpy(json + json_len, "]}", 3);
    mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return json;
}

char *mtp_bridge_list_directory_json(mtp_bridge_handle_t *handle, uint32_t storage_id, const char *path, int recursive) {
    if (handle == NULL) {
        return NULL;
    }

    pthread_mutex_lock(&handle->mutex);
    if (handle->destroyed) {
        mtp_bridge_set_error(handle, "libmtp bridge handle is destroyed");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    if (handle->device == NULL) {
        mtp_bridge_set_error(handle, "Device is not connected");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }

    uint32_t parent_id = 0;
    int is_folder = 0;
    if (mtp_bridge_resolve_object_id_locked(handle, storage_id, path, &parent_id, &is_folder) != 0) {
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    if (!is_folder) {
        mtp_bridge_set_error(handle, "MTP path is not a folder");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }

    const char *parent_path = (path == NULL || path[0] == '\0') ? "/" : path;
    mtp_bridge_json_builder_t builder;
    if (mtp_bridge_json_builder_init(&builder, "{\"error\":null,\"data\":[") != 0) {
        mtp_bridge_set_error(handle, "Failed to allocate MTP directory JSON");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }

    int first = 1;
    if (mtp_bridge_append_directory_entries(handle, storage_id, parent_id, parent_path, recursive != 0, &builder, &first) != 0
        || mtp_bridge_json_builder_append(&builder, "]}") != 0) {
        mtp_bridge_json_builder_destroy(&builder);
        if (handle->last_error[0] == '\0') {
            mtp_bridge_set_error(handle, "Failed to allocate MTP directory JSON");
        }
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }

    mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return builder.data;
}

static int mtp_bridge_is_root_path(const char *path) {
    return path == NULL || path[0] == '\0' || strcmp(path, "/") == 0;
}

static int mtp_bridge_is_missing_path_error(const mtp_bridge_handle_t *handle) {
    return strcmp(handle->last_error, "MTP path was not found") == 0
        || strcmp(handle->last_error, "An MTP path component is not a folder") == 0;
}

typedef struct {
    const char *full_path;
    const char *name;
    mtp_bridge_progress_callback_t callback;
    void *context;
} mtp_bridge_transfer_context_t;

static const char *mtp_bridge_basename(const char *path) {
    const char *slash = strrchr(path, '/');
    return slash == NULL ? path : slash + 1;
}

// Returns 0 when found, 1 when absent, and -1 when listing the directory fails.
static int mtp_bridge_find_child_by_name_locked(
    mtp_bridge_handle_t *handle,
    uint32_t storage_id,
    uint32_t parent_id,
    const char *name,
    uint32_t *object_id,
    int *is_folder) {
    LIBMTP_Clear_Errorstack(handle->device);
    LIBMTP_file_t *files = LIBMTP_Get_Files_And_Folders(handle->device, storage_id, parent_id);
    if (files == NULL) {
        return mtp_bridge_set_error_from_errorstack_if_present(handle, "Failed to read MTP directory") ? -1 : 1;
    }

    for (LIBMTP_file_t *file = files; file != NULL; file = file->next) {
        if (file->filename != NULL && strcmp(file->filename, name) == 0) {
            *object_id = file->item_id;
            if (is_folder != NULL) {
                *is_folder = file->filetype == LIBMTP_FILETYPE_FOLDER;
            }
            mtp_bridge_destroy_file_list(files);
            return 0;
        }
    }

    mtp_bridge_destroy_file_list(files);
    return 1;
}

static int mtp_bridge_make_temporary_upload_name_locked(
    mtp_bridge_handle_t *handle,
    uint32_t storage_id,
    uint32_t parent_id,
    const char *purpose,
    char *name,
    size_t name_size) {
    unsigned long seed = (unsigned long)time(NULL) ^ (unsigned long)getpid();
    for (unsigned int attempt = 0; attempt < 100; attempt++) {
        int written = snprintf(name, name_size, ".macmtp-%s-%08lx-%u", purpose, seed, attempt);
        if (written < 0 || (size_t)written >= name_size) {
            mtp_bridge_set_error(handle, "Failed to create temporary MTP upload name");
            return -1;
        }

        uint32_t ignored_object_id = 0;
        int lookup = mtp_bridge_find_child_by_name_locked(
            handle, storage_id, parent_id, name, &ignored_object_id, NULL);
        if (lookup == 1) {
            return 0;
        }
        if (lookup < 0) {
            return -1;
        }
    }

    mtp_bridge_set_error(handle, "Failed to allocate a unique temporary MTP upload name");
    return -1;
}

static int mtp_bridge_rename_object_locked(
    mtp_bridge_handle_t *handle,
    uint32_t object_id,
    const char *new_name,
    const char *error_message) {
    LIBMTP_Clear_Errorstack(handle->device);
    if (LIBMTP_Set_Object_Filename(handle->device, object_id, (char *)new_name) != 0) {
        mtp_bridge_set_error_from_errorstack(handle, error_message);
        return -1;
    }
    return 0;
}

static int mtp_bridge_delete_object_locked(
    mtp_bridge_handle_t *handle,
    uint32_t object_id,
    const char *error_message) {
    LIBMTP_Clear_Errorstack(handle->device);
    if (LIBMTP_Delete_Object(handle->device, object_id) != 0) {
        mtp_bridge_set_error_from_errorstack(handle, error_message);
        return -1;
    }
    return 0;
}

static void mtp_bridge_append_error(mtp_bridge_handle_t *handle, const char *detail) {
    char primary[sizeof(handle->last_error)];
    snprintf(
        primary,
        sizeof(primary),
        "%s",
        handle->last_error[0] == '\0' ? "MTP upload failed" : handle->last_error);
    snprintf(handle->last_error, sizeof(handle->last_error), "%s; %s", primary, detail);
}

static void mtp_bridge_cleanup_object_preserving_error_locked(
    mtp_bridge_handle_t *handle,
    uint32_t object_id,
    const char *object_description) {
    char primary[sizeof(handle->last_error)];
    snprintf(primary, sizeof(primary), "%s", handle->last_error);

    if (mtp_bridge_delete_object_locked(handle, object_id, "Failed to delete MTP object during rollback") != 0) {
        char cleanup_error[sizeof(handle->last_error)];
        snprintf(cleanup_error, sizeof(cleanup_error), "%s", handle->last_error);
        mtp_bridge_set_error(handle, primary);
        char detail[sizeof(handle->last_error)];
        snprintf(detail, sizeof(detail), "could not delete %s: %s", object_description, cleanup_error);
        mtp_bridge_append_error(handle, detail);
        return;
    }

    mtp_bridge_set_error(handle, primary);
}

static void mtp_bridge_cleanup_named_child_preserving_error_locked(
    mtp_bridge_handle_t *handle,
    uint32_t storage_id,
    uint32_t parent_id,
    const char *name,
    const char *object_description) {
    char primary[sizeof(handle->last_error)];
    snprintf(primary, sizeof(primary), "%s", handle->last_error);

    uint32_t object_id = 0;
    int lookup = mtp_bridge_find_child_by_name_locked(
        handle, storage_id, parent_id, name, &object_id, NULL);
    if (lookup == 0) {
        mtp_bridge_set_error(handle, primary);
        mtp_bridge_cleanup_object_preserving_error_locked(handle, object_id, object_description);
    } else if (lookup < 0) {
        char cleanup_error[sizeof(handle->last_error)];
        snprintf(cleanup_error, sizeof(cleanup_error), "%s", handle->last_error);
        mtp_bridge_set_error(handle, primary);
        char detail[sizeof(handle->last_error)];
        snprintf(detail, sizeof(detail), "could not find %s for cleanup: %s", object_description, cleanup_error);
        mtp_bridge_append_error(handle, detail);
    } else {
        mtp_bridge_set_error(handle, primary);
    }
}

static void mtp_bridge_restore_object_name_preserving_error_locked(
    mtp_bridge_handle_t *handle,
    uint32_t object_id,
    const char *name,
    const char *backup_name) {
    char primary[sizeof(handle->last_error)];
    snprintf(primary, sizeof(primary), "%s", handle->last_error);

    if (mtp_bridge_rename_object_locked(
            handle, object_id, name, "Failed to restore original MTP file name") != 0) {
        char rollback_error[sizeof(handle->last_error)];
        snprintf(rollback_error, sizeof(rollback_error), "%s", handle->last_error);
        mtp_bridge_set_error(handle, primary);
        char detail[sizeof(handle->last_error)];
        snprintf(
            detail,
            sizeof(detail),
            "could not restore original MTP file from backup '%s': %s",
            backup_name,
            rollback_error);
        mtp_bridge_append_error(handle, detail);
        return;
    }

    mtp_bridge_set_error(handle, primary);
}

static int mtp_bridge_transfer_progress_callback(
    uint64_t const sent,
    uint64_t const total,
    void const *const data) {
    const mtp_bridge_transfer_context_t *transfer = data;
    if (transfer != NULL && transfer->callback != NULL) {
        transfer->callback(transfer->full_path, transfer->name, sent, total, transfer->context);
    }
    return 0;
}

int mtp_bridge_download_file(
    mtp_bridge_handle_t *handle,
    uint32_t storage_id,
    const char *source_path,
    const char *destination_path,
    mtp_bridge_progress_callback_t callback,
    void *context) {
    if (handle == NULL) {
        return -1;
    }
    pthread_mutex_lock(&handle->mutex);
    if (handle->destroyed) {
        mtp_bridge_set_error(handle, "libmtp bridge handle is destroyed");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    if (handle->device == NULL) {
        mtp_bridge_set_error(handle, "Device is not connected");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    if (source_path == NULL || source_path[0] == '\0' || destination_path == NULL || destination_path[0] == '\0') {
        mtp_bridge_set_error(handle, "MTP download requires source and destination paths");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }

    uint32_t object_id = 0;
    int is_folder = 0;
    if (mtp_bridge_resolve_object_id_locked(handle, storage_id, source_path, &object_id, &is_folder) != 0) {
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    if (is_folder) {
        mtp_bridge_set_error(handle, "MTP download source is a folder");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }

    mtp_bridge_transfer_context_t transfer = {
        .full_path = source_path,
        .name = mtp_bridge_basename(source_path),
        .callback = callback,
        .context = context,
    };
    LIBMTP_Clear_Errorstack(handle->device);
    if (LIBMTP_Get_File_To_File(
            handle->device,
            object_id,
            destination_path,
            mtp_bridge_transfer_progress_callback,
            &transfer) != 0) {
        mtp_bridge_set_error_from_errorstack(handle, "Failed to download MTP file");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }

    mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return 0;
}

int mtp_bridge_upload_file(
    mtp_bridge_handle_t *handle,
    uint32_t storage_id,
    const char *source_path,
    const char *destination_dir,
    mtp_bridge_progress_callback_t callback,
    void *context) {
    if (handle == NULL) {
        return -1;
    }
    pthread_mutex_lock(&handle->mutex);
    if (handle->destroyed) {
        mtp_bridge_set_error(handle, "libmtp bridge handle is destroyed");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    if (handle->device == NULL) {
        mtp_bridge_set_error(handle, "Device is not connected");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    if (source_path == NULL || source_path[0] == '\0' || destination_dir == NULL || destination_dir[0] == '\0') {
        mtp_bridge_set_error(handle, "MTP upload requires source and destination paths");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }

    struct stat source_stat;
    if (stat(source_path, &source_stat) != 0 || !S_ISREG(source_stat.st_mode)) {
        mtp_bridge_set_error(handle, "MTP upload source must be a readable regular file");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    const char *name = mtp_bridge_basename(source_path);
    if (name[0] == '\0') {
        mtp_bridge_set_error(handle, "MTP upload source must include a file name");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }

    uint32_t parent_id = 0;
    int is_folder = 0;
    if (mtp_bridge_resolve_object_id_locked(handle, storage_id, destination_dir, &parent_id, &is_folder) != 0) {
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    if (!is_folder) {
        mtp_bridge_set_error(handle, "MTP upload destination is not a folder");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }

    uint32_t existing_object_id = 0;
    int existing_is_folder = 0;
    int target_lookup = mtp_bridge_find_child_by_name_locked(
        handle, storage_id, parent_id, name, &existing_object_id, &existing_is_folder);
    if (target_lookup < 0) {
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    if (target_lookup == 0 && existing_is_folder) {
        mtp_bridge_set_error(handle, "Cannot overwrite an MTP folder with a file");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }

    char temporary_name[64];
    const char *upload_name = name;
    if (target_lookup == 0) {
        if (mtp_bridge_make_temporary_upload_name_locked(
                handle, storage_id, parent_id, "upload", temporary_name, sizeof(temporary_name)) != 0) {
            pthread_mutex_unlock(&handle->mutex);
            return -1;
        }
        upload_name = temporary_name;
    }

    LIBMTP_file_t *metadata = LIBMTP_new_file_t();
    if (metadata == NULL) {
        mtp_bridge_set_error(handle, "Failed to allocate MTP file metadata");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    metadata->filename = strdup(upload_name);
    if (metadata->filename == NULL) {
        LIBMTP_destroy_file_t(metadata);
        mtp_bridge_set_error(handle, "Failed to allocate MTP file name");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    metadata->filesize = (uint64_t)source_stat.st_size;
    metadata->parent_id = parent_id;
    metadata->storage_id = storage_id;
    metadata->modificationdate = source_stat.st_mtime;
    metadata->filetype = LIBMTP_FILETYPE_UNKNOWN;

    mtp_bridge_transfer_context_t transfer = {
        .full_path = source_path,
        .name = name,
        .callback = callback,
        .context = context,
    };
    LIBMTP_Clear_Errorstack(handle->device);
    int result = LIBMTP_Send_File_From_File(
        handle->device,
        source_path,
        metadata,
        mtp_bridge_transfer_progress_callback,
        &transfer);
    LIBMTP_destroy_file_t(metadata);
    if (result != 0) {
        mtp_bridge_set_error_from_errorstack(handle, "Failed to upload MTP file");
        if (target_lookup == 0) {
            mtp_bridge_cleanup_named_child_preserving_error_locked(
                handle, storage_id, parent_id, temporary_name, "temporary MTP upload");
        }
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }

    if (target_lookup == 0) {
        uint32_t temporary_object_id = 0;
        int temporary_lookup = mtp_bridge_find_child_by_name_locked(
            handle, storage_id, parent_id, temporary_name, &temporary_object_id, NULL);
        if (temporary_lookup != 0) {
            if (temporary_lookup == 1) {
                mtp_bridge_set_error(handle, "Uploaded temporary MTP file could not be found");
            }
            mtp_bridge_cleanup_named_child_preserving_error_locked(
                handle, storage_id, parent_id, temporary_name, "temporary MTP upload");
            pthread_mutex_unlock(&handle->mutex);
            return -1;
        }

        char backup_name[64];
        if (mtp_bridge_make_temporary_upload_name_locked(
                handle, storage_id, parent_id, "backup", backup_name, sizeof(backup_name)) != 0) {
            mtp_bridge_cleanup_object_preserving_error_locked(
                handle, temporary_object_id, "temporary MTP upload");
            pthread_mutex_unlock(&handle->mutex);
            return -1;
        }

        if (mtp_bridge_rename_object_locked(
                handle, existing_object_id, backup_name, "Failed to rename existing MTP file for replacement") != 0) {
            mtp_bridge_cleanup_object_preserving_error_locked(
                handle, temporary_object_id, "temporary MTP upload");
            pthread_mutex_unlock(&handle->mutex);
            return -1;
        }

        if (mtp_bridge_rename_object_locked(
                handle, temporary_object_id, name, "Failed to rename temporary MTP replacement") != 0) {
            mtp_bridge_restore_object_name_preserving_error_locked(
                handle, existing_object_id, name, backup_name);
            mtp_bridge_cleanup_object_preserving_error_locked(
                handle, temporary_object_id, "temporary MTP upload");
            pthread_mutex_unlock(&handle->mutex);
            return -1;
        }

        // The replacement has already been published. Emit the cleanup error
        // for diagnostics, but do not report a committed file as a failed transfer.
        if (mtp_bridge_delete_object_locked(handle, existing_object_id, "Failed to delete MTP backup after replacement") != 0) {
            char cleanup_error[sizeof(handle->last_error)];
            snprintf(cleanup_error, sizeof(cleanup_error), "%s", handle->last_error);
            fprintf(stderr, "MacMTP libmtp warning: %s\n", cleanup_error);
            mtp_bridge_set_error(handle, "");
            pthread_mutex_unlock(&handle->mutex);
            return 0;
        }
    }

    mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return 0;
}

int mtp_bridge_create_folder(mtp_bridge_handle_t *handle, uint32_t storage_id, const char *path) {
    if (handle == NULL) {
        return -1;
    }

    pthread_mutex_lock(&handle->mutex);
    if (handle->destroyed) {
        mtp_bridge_set_error(handle, "libmtp bridge handle is destroyed");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    if (handle->device == NULL) {
        mtp_bridge_set_error(handle, "Device is not connected");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    if (mtp_bridge_is_root_path(path)) {
        mtp_bridge_set_error(handle, "MTP folder path must include a name");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }

    char *path_copy = strdup(path);
    if (path_copy == NULL) {
        mtp_bridge_set_error(handle, "Failed to allocate MTP folder path");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }

    char *last_slash = strrchr(path_copy, '/');
    char *name = last_slash == NULL ? path_copy : last_slash + 1;
    const char *parent_path = "/";
    if (name[0] == '\0') {
        free(path_copy);
        mtp_bridge_set_error(handle, "MTP folder path must include a name");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    if (last_slash != NULL && last_slash != path_copy) {
        *last_slash = '\0';
        parent_path = path_copy;
    }

    uint32_t parent_id = 0;
    int is_folder = 0;
    if (mtp_bridge_resolve_object_id_locked(handle, storage_id, parent_path, &parent_id, &is_folder) != 0) {
        free(path_copy);
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    if (!is_folder) {
        free(path_copy);
        mtp_bridge_set_error(handle, "MTP parent path is not a folder");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }

    LIBMTP_Clear_Errorstack(handle->device);
    uint32_t object_id = LIBMTP_Create_Folder(handle->device, name, parent_id, storage_id);
    free(path_copy);
    if (object_id == 0) {
        mtp_bridge_set_error_from_errorstack(handle, "Failed to create MTP folder");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }

    mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return 0;
}

int mtp_bridge_delete_path(mtp_bridge_handle_t *handle, uint32_t storage_id, const char *path) {
    if (handle == NULL) {
        return -1;
    }

    pthread_mutex_lock(&handle->mutex);
    if (handle->destroyed) {
        mtp_bridge_set_error(handle, "libmtp bridge handle is destroyed");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    if (handle->device == NULL) {
        mtp_bridge_set_error(handle, "Device is not connected");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    if (mtp_bridge_is_root_path(path)) {
        mtp_bridge_set_error(handle, "MTP root path cannot be deleted");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }

    uint32_t object_id = 0;
    if (mtp_bridge_resolve_object_id_locked(handle, storage_id, path, &object_id, NULL) != 0) {
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }

    LIBMTP_Clear_Errorstack(handle->device);
    if (LIBMTP_Delete_Object(handle->device, object_id) != 0) {
        mtp_bridge_set_error_from_errorstack(handle, "Failed to delete MTP object");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }

    mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return 0;
}

int mtp_bridge_rename_path(
    mtp_bridge_handle_t *handle,
    uint32_t storage_id,
    const char *path,
    const char *new_name) {
    if (handle == NULL) {
        return -1;
    }

    pthread_mutex_lock(&handle->mutex);
    if (handle->destroyed) {
        mtp_bridge_set_error(handle, "libmtp bridge handle is destroyed");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    if (handle->device == NULL) {
        mtp_bridge_set_error(handle, "Device is not connected");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    if (mtp_bridge_is_root_path(path)) {
        mtp_bridge_set_error(handle, "MTP root path cannot be renamed");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    if (new_name == NULL || new_name[0] == '\0' || strchr(new_name, '/') != NULL) {
        mtp_bridge_set_error(handle, "MTP object name must be a non-empty path component");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }

    uint32_t object_id = 0;
    if (mtp_bridge_resolve_object_id_locked(handle, storage_id, path, &object_id, NULL) != 0) {
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }

    LIBMTP_Clear_Errorstack(handle->device);
    LIBMTP_file_t *metadata = LIBMTP_Get_Filemetadata(handle->device, object_id);
    if (metadata == NULL) {
        mtp_bridge_set_error_from_errorstack(handle, "Failed to read MTP object metadata");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    LIBMTP_destroy_file_t(metadata);

    LIBMTP_Clear_Errorstack(handle->device);
    if (LIBMTP_Set_Object_Filename(handle->device, object_id, (char *)new_name) != 0) {
        mtp_bridge_set_error_from_errorstack(handle, "Failed to rename MTP object");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }

    mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return 0;
}

int mtp_bridge_move_path(
    mtp_bridge_handle_t *handle,
    uint32_t storage_id,
    const char *source_path,
    const char *destination_parent_path) {
    if (handle == NULL) {
        return -1;
    }

    pthread_mutex_lock(&handle->mutex);
    if (handle->destroyed) {
        mtp_bridge_set_error(handle, "libmtp bridge handle is destroyed");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    if (handle->device == NULL) {
        mtp_bridge_set_error(handle, "Device is not connected");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    if (mtp_bridge_is_root_path(source_path)) {
        mtp_bridge_set_error(handle, "MTP root path cannot be moved");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }

    uint32_t object_id = 0;
    if (mtp_bridge_resolve_object_id_locked(handle, storage_id, source_path, &object_id, NULL) != 0) {
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }

    uint32_t destination_parent_id = 0;
    int destination_is_folder = 0;
    if (mtp_bridge_resolve_object_id_locked(
            handle,
            storage_id,
            destination_parent_path,
            &destination_parent_id,
            &destination_is_folder) != 0) {
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    if (!destination_is_folder) {
        mtp_bridge_set_error(handle, "MTP move destination is not a folder");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }

    uint32_t existing_id = 0;
    int existing_is_folder = 0;
    int existing_lookup = mtp_bridge_find_child_by_name_locked(
        handle,
        storage_id,
        destination_parent_id,
        mtp_bridge_basename(source_path),
        &existing_id,
        &existing_is_folder);
    if (existing_lookup < 0) {
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    if (existing_lookup == 0 && existing_id != object_id) {
        mtp_bridge_set_error(handle, "MTP move destination already contains an item with the same name");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    if (existing_lookup == 0 && existing_id == object_id) {
        mtp_bridge_set_error(handle, "");
        pthread_mutex_unlock(&handle->mutex);
        return 0;
    }

    uint32_t move_parent_id = mtp_bridge_is_root_path(destination_parent_path) ? 0 : destination_parent_id;

    LIBMTP_Clear_Errorstack(handle->device);
    if (LIBMTP_Move_Object(handle->device, object_id, storage_id, move_parent_id) != 0) {
        mtp_bridge_set_error_from_errorstack(handle, "Failed to move MTP object");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }

    mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return 0;
}

char *mtp_bridge_file_exists_json(mtp_bridge_handle_t *handle, uint32_t storage_id, const char **paths, int count) {
    if (handle == NULL) {
        return NULL;
    }
    if (count < 0 || (count > 0 && paths == NULL)) {
        mtp_bridge_set_error(handle, "Invalid MTP path list");
        return NULL;
    }

    pthread_mutex_lock(&handle->mutex);
    if (handle->destroyed) {
        mtp_bridge_set_error(handle, "libmtp bridge handle is destroyed");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    if (handle->device == NULL) {
        mtp_bridge_set_error(handle, "Device is not connected");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }

    mtp_bridge_json_builder_t builder;
    if (mtp_bridge_json_builder_init(&builder, "{\"error\":null,\"data\":[") != 0) {
        mtp_bridge_set_error(handle, "Failed to allocate MTP existence JSON");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }

    for (int index = 0; index < count; index++) {
        const char *path = paths[index];
        if (path == NULL) {
            mtp_bridge_json_builder_destroy(&builder);
            mtp_bridge_set_error(handle, "Invalid MTP path");
            pthread_mutex_unlock(&handle->mutex);
            return NULL;
        }

        uint32_t object_id = 0;
        int exists = mtp_bridge_resolve_object_id_locked(handle, storage_id, path, &object_id, NULL) == 0;
        if (!exists && !mtp_bridge_is_missing_path_error(handle)) {
            mtp_bridge_json_builder_destroy(&builder);
            pthread_mutex_unlock(&handle->mutex);
            return NULL;
        }

        char *escaped_path = mtp_bridge_json_escape(path);
        char *entry = escaped_path == NULL
            ? NULL
            : mtp_bridge_format_alloc(
                "%s{\"fullpath\":\"%s\",\"exists\":%s}",
                index == 0 ? "" : ",",
                escaped_path,
                exists ? "true" : "false");
        free(escaped_path);
        if (entry == NULL || mtp_bridge_json_builder_append(&builder, entry) != 0) {
            free(entry);
            mtp_bridge_json_builder_destroy(&builder);
            mtp_bridge_set_error(handle, "Failed to allocate MTP existence JSON");
            pthread_mutex_unlock(&handle->mutex);
            return NULL;
        }
        free(entry);
    }

    if (mtp_bridge_json_builder_append(&builder, "]}") != 0) {
        mtp_bridge_json_builder_destroy(&builder);
        mtp_bridge_set_error(handle, "Failed to allocate MTP existence JSON");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }

    mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return builder.data;
}

void mtp_bridge_set_debug(int level) {
    LIBMTP_Set_Debug(level);
}

void mtp_bridge_free_data(void *value) {
    LIBMTP_FreeMemory(value);
}

static int mtp_bridge_lock_connected(mtp_bridge_handle_t *handle) {
    if (handle == NULL) {
        return -1;
    }
    pthread_mutex_lock(&handle->mutex);
    if (handle->destroyed) {
        mtp_bridge_set_error(handle, "libmtp bridge handle is destroyed");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    if (handle->device == NULL) {
        mtp_bridge_set_error(handle, "Device is not connected");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    return 0;
}

static char *mtp_bridge_take_json_or_error(mtp_bridge_handle_t *handle, mtp_bridge_json_builder_t *builder, const char *error) {
    if (mtp_bridge_json_builder_append(builder, "]}") != 0) {
        mtp_bridge_json_builder_destroy(builder);
        mtp_bridge_set_error(handle, error);
        return NULL;
    }
    mtp_bridge_set_error(handle, "");
    return builder->data;
}

static int mtp_bridge_append_u32_array(mtp_bridge_json_builder_t *builder, const uint32_t *values, uint32_t count) {
    if (mtp_bridge_json_builder_append(builder, "[") != 0) {
        return -1;
    }
    for (uint32_t i = 0; i < count; i++) {
        char *entry = mtp_bridge_format_alloc("%s%u", i == 0 ? "" : ",", values[i]);
        if (entry == NULL || mtp_bridge_json_builder_append(builder, entry) != 0) {
            free(entry);
            return -1;
        }
        free(entry);
    }
    return mtp_bridge_json_builder_append(builder, "]");
}

static int mtp_bridge_append_file_metadata(mtp_bridge_json_builder_t *builder, LIBMTP_file_t *file, const char *prefix) {
    if (file == NULL) {
        return -1;
    }
    char date[25];
    if (mtp_bridge_format_date(file->modificationdate, date) != 0) {
        snprintf(date, sizeof(date), "1970-01-01T00:00:00.000Z");
    }
    char *name = mtp_bridge_json_escape(file->filename);
    const char *type_description_raw = LIBMTP_Get_Filetype_Description(file->filetype);
    char *type_description = mtp_bridge_json_escape(type_description_raw);
    char *entry = (name == NULL || type_description == NULL)
        ? NULL
        : mtp_bridge_format_alloc(
            "%s{\"objectId\":%u,\"parentId\":%u,\"storageId\":%u,\"filename\":\"%s\",\"filesize\":%llu,\"modificationDate\":\"%s\",\"filetype\":%d,\"filetypeDescription\":\"%s\"}",
            prefix,
            file->item_id,
            file->parent_id,
            file->storage_id,
            name,
            (unsigned long long)file->filesize,
            date,
            file->filetype,
            type_description);
    free(name);
    free(type_description);
    if (entry == NULL) {
        return -1;
    }
    int result = mtp_bridge_json_builder_append(builder, entry);
    free(entry);
    return result;
}

static int mtp_bridge_append_track_metadata(mtp_bridge_json_builder_t *builder, LIBMTP_track_t *track, const char *prefix) {
    if (track == NULL) {
        return -1;
    }
    char date[25];
    if (mtp_bridge_format_date(track->modificationdate, date) != 0) {
        snprintf(date, sizeof(date), "1970-01-01T00:00:00.000Z");
    }
    char *title = mtp_bridge_json_escape(track->title);
    char *artist = mtp_bridge_json_escape(track->artist);
    char *composer = mtp_bridge_json_escape(track->composer);
    char *genre = mtp_bridge_json_escape(track->genre);
    char *album = mtp_bridge_json_escape(track->album);
    char *recording_date = mtp_bridge_json_escape(track->date);
    char *filename = mtp_bridge_json_escape(track->filename);
    if (title == NULL || artist == NULL || composer == NULL || genre == NULL || album == NULL
        || recording_date == NULL || filename == NULL) {
        free(title); free(artist); free(composer); free(genre); free(album); free(recording_date); free(filename);
        return -1;
    }
    char *entry = mtp_bridge_format_alloc(
        "%s{\"trackId\":%u,\"parentId\":%u,\"storageId\":%u,\"title\":\"%s\",\"artist\":\"%s\",\"composer\":\"%s\",\"genre\":\"%s\",\"album\":\"%s\",\"date\":\"%s\",\"filename\":\"%s\",\"trackNumber\":%u,\"duration\":%u,\"sampleRate\":%u,\"channels\":%u,\"waveCodec\":%u,\"bitrate\":%u,\"bitrateType\":%u,\"rating\":%u,\"useCount\":%u,\"filesize\":%llu,\"modificationDate\":\"%s\",\"filetype\":%d}",
        prefix,
        track->item_id,
        track->parent_id,
        track->storage_id,
        title,
        artist,
        composer,
        genre,
        album,
        recording_date,
        filename,
        track->tracknumber,
        track->duration,
        track->samplerate,
        track->nochannels,
        track->wavecodec,
        track->bitrate,
        track->bitratetype,
        track->rating,
        track->usecount,
        (unsigned long long)track->filesize,
        date,
        track->filetype);
    free(title); free(artist); free(composer); free(genre); free(album); free(recording_date); free(filename);
    if (entry == NULL) {
        return -1;
    }
    int result = mtp_bridge_json_builder_append(builder, entry);
    free(entry);
    return result;
}

static int mtp_bridge_append_playlist_metadata(mtp_bridge_json_builder_t *builder, LIBMTP_playlist_t *playlist, const char *prefix) {
    if (playlist == NULL) {
        return -1;
    }
    char *name = mtp_bridge_json_escape(playlist->name);
    char *entry = name == NULL
        ? NULL
        : mtp_bridge_format_alloc(
            "%s{\"playlistId\":%u,\"parentId\":%u,\"storageId\":%u,\"name\":\"%s\",\"tracks\":",
            prefix,
            playlist->playlist_id,
            playlist->parent_id,
            playlist->storage_id,
            name);
    free(name);
    if (entry == NULL || mtp_bridge_json_builder_append(builder, entry) != 0) {
        free(entry);
        return -1;
    }
    free(entry);
    return mtp_bridge_append_u32_array(builder, playlist->tracks, playlist->no_tracks) == 0
        && mtp_bridge_json_builder_append(builder, "}") == 0 ? 0 : -1;
}

static int mtp_bridge_append_album_metadata(mtp_bridge_json_builder_t *builder, LIBMTP_album_t *album, const char *prefix) {
    if (album == NULL) {
        return -1;
    }
    char *name = mtp_bridge_json_escape(album->name);
    char *artist = mtp_bridge_json_escape(album->artist);
    char *composer = mtp_bridge_json_escape(album->composer);
    char *genre = mtp_bridge_json_escape(album->genre);
    char *entry = (name == NULL || artist == NULL || composer == NULL || genre == NULL)
        ? NULL
        : mtp_bridge_format_alloc(
            "%s{\"albumId\":%u,\"parentId\":%u,\"storageId\":%u,\"name\":\"%s\",\"artist\":\"%s\",\"composer\":\"%s\",\"genre\":\"%s\",\"tracks\":",
            prefix,
            album->album_id,
            album->parent_id,
            album->storage_id,
            name,
            artist,
            composer,
            genre);
    free(name); free(artist); free(composer); free(genre);
    if (entry == NULL || mtp_bridge_json_builder_append(builder, entry) != 0) {
        free(entry);
        return -1;
    }
    free(entry);
    return mtp_bridge_append_u32_array(builder, album->tracks, album->no_tracks) == 0
        && mtp_bridge_json_builder_append(builder, "}") == 0 ? 0 : -1;
}

static int mtp_bridge_append_folder_tree(mtp_bridge_json_builder_t *builder, LIBMTP_folder_t *folder, int *first) {
    for (LIBMTP_folder_t *node = folder; node != NULL; node = node->sibling) {
        char *name = mtp_bridge_json_escape(node->name);
        char *entry = name == NULL
            ? NULL
            : mtp_bridge_format_alloc(
                "%s{\"folderId\":%u,\"parentId\":%u,\"storageId\":%u,\"name\":\"%s\"}",
                *first ? "" : ",",
                node->folder_id,
                node->parent_id,
                node->storage_id,
                name);
        free(name);
        if (entry == NULL || mtp_bridge_json_builder_append(builder, entry) != 0) {
            free(entry);
            return -1;
        }
        free(entry);
        *first = 0;
        if (node->child != NULL && mtp_bridge_append_folder_tree(builder, node->child, first) != 0) {
            return -1;
        }
    }
    return 0;
}

char *mtp_bridge_supported_devices_json(void) {
    LIBMTP_device_entry_t *devices = NULL;
    int count = 0;
    if (LIBMTP_Get_Supported_Devices_List(&devices, &count) != 0) {
        return NULL;
    }
    mtp_bridge_json_builder_t builder;
    if (mtp_bridge_json_builder_init(&builder, "{\"error\":null,\"data\":[") != 0) {
        return NULL;
    }
    for (int i = 0; i < count; i++) {
        char *vendor = mtp_bridge_json_escape(devices[i].vendor);
        char *product = mtp_bridge_json_escape(devices[i].product);
        char *entry = (vendor == NULL || product == NULL)
            ? NULL
            : mtp_bridge_format_alloc(
                "%s{\"vendor\":\"%s\",\"vendorId\":%u,\"product\":\"%s\",\"productId\":%u,\"deviceFlags\":%u}",
                i == 0 ? "" : ",",
                vendor,
                devices[i].vendor_id,
                product,
                devices[i].product_id,
                devices[i].device_flags);
        free(vendor);
        free(product);
        if (entry == NULL || mtp_bridge_json_builder_append(&builder, entry) != 0) {
            free(entry);
            mtp_bridge_json_builder_destroy(&builder);
            if (devices != NULL) {
                LIBMTP_FreeMemory(devices);
            }
            return NULL;
        }
        free(entry);
    }
    if (devices != NULL) {
        LIBMTP_FreeMemory(devices);
    }
    return mtp_bridge_take_json_or_error(NULL, &builder, "Failed to allocate supported devices JSON");
}

char *mtp_bridge_raw_devices_json(void) {
    LIBMTP_raw_device_t *devices = NULL;
    int count = 0;
    LIBMTP_error_number_t error = LIBMTP_Detect_Raw_Devices(&devices, &count);
    if (error != LIBMTP_ERROR_NONE && error != LIBMTP_ERROR_NO_DEVICE_ATTACHED) {
        return NULL;
    }
    mtp_bridge_json_builder_t builder;
    if (mtp_bridge_json_builder_init(&builder, "{\"error\":null,\"data\":[") != 0) {
        if (devices != NULL) {
            LIBMTP_FreeMemory(devices);
        }
        return NULL;
    }
    for (int i = 0; i < count; i++) {
        char *vendor = mtp_bridge_json_escape(devices[i].device_entry.vendor);
        char *product = mtp_bridge_json_escape(devices[i].device_entry.product);
        char *entry = (vendor == NULL || product == NULL)
            ? NULL
            : mtp_bridge_format_alloc(
                "%s{\"vendor\":\"%s\",\"vendorId\":%u,\"product\":\"%s\",\"productId\":%u,\"deviceFlags\":%u,\"busLocation\":%u,\"deviceNumber\":%u}",
                i == 0 ? "" : ",",
                vendor,
                devices[i].device_entry.vendor_id,
                product,
                devices[i].device_entry.product_id,
                devices[i].device_entry.device_flags,
                devices[i].bus_location,
                devices[i].devnum);
        free(vendor);
        free(product);
        if (entry == NULL || mtp_bridge_json_builder_append(&builder, entry) != 0) {
            free(entry);
            mtp_bridge_json_builder_destroy(&builder);
            if (devices != NULL) {
                LIBMTP_FreeMemory(devices);
            }
            return NULL;
        }
        free(entry);
    }
    if (devices != NULL) {
        LIBMTP_FreeMemory(devices);
    }
    return mtp_bridge_take_json_or_error(NULL, &builder, "Failed to allocate raw devices JSON");
}

int mtp_bridge_check_specific_device(int busno, int devno) {
    return LIBMTP_Check_Specific_Device(busno, devno);
}

int mtp_bridge_reset_device(mtp_bridge_handle_t *handle) {
    if (mtp_bridge_lock_connected(handle) != 0) {
        return -1;
    }
    LIBMTP_Clear_Errorstack(handle->device);
    int result = LIBMTP_Reset_Device(handle->device);
    if (result != 0) {
        mtp_bridge_set_error_from_errorstack(handle, "Failed to reset MTP device");
    } else {
        mtp_bridge_set_error(handle, "");
    }
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

char *mtp_bridge_device_extended_info_json(mtp_bridge_handle_t *handle) {
    if (mtp_bridge_lock_connected(handle) != 0) {
        return NULL;
    }
    char *manufacturer_raw = LIBMTP_Get_Manufacturername(handle->device);
    char *model_raw = LIBMTP_Get_Modelname(handle->device);
    char *serial_raw = LIBMTP_Get_Serialnumber(handle->device);
    char *version_raw = LIBMTP_Get_Deviceversion(handle->device);
    char *friendly_raw = LIBMTP_Get_Friendlyname(handle->device);
    char *sync_raw = LIBMTP_Get_Syncpartner(handle->device);
    uint8_t max_battery = 0;
    uint8_t current_battery = 0;
    int has_battery = LIBMTP_Get_Batterylevel(handle->device, &max_battery, &current_battery) == 0;

    char *manufacturer = mtp_bridge_json_escape(manufacturer_raw);
    char *model = mtp_bridge_json_escape(model_raw);
    char *serial = mtp_bridge_json_escape(serial_raw);
    char *version = mtp_bridge_json_escape(version_raw);
    char *friendly = mtp_bridge_json_escape(friendly_raw);
    char *sync = mtp_bridge_json_escape(sync_raw);
    char *json = (manufacturer == NULL || model == NULL || serial == NULL || version == NULL || friendly == NULL || sync == NULL)
        ? NULL
        : mtp_bridge_format_alloc(
            "{\"error\":null,\"data\":{\"manufacturer\":\"%s\",\"model\":\"%s\",\"serialNumber\":\"%s\",\"deviceVersion\":\"%s\",\"friendlyName\":\"%s\",\"syncPartner\":\"%s\",\"battery\":{\"available\":%s,\"maximum\":%u,\"current\":%u},\"defaultFolders\":{\"music\":%u,\"playlist\":%u,\"picture\":%u,\"video\":%u,\"organizer\":%u,\"zencast\":%u,\"album\":%u,\"text\":%u}}}",
            manufacturer,
            model,
            serial,
            version,
            friendly,
            sync,
            has_battery ? "true" : "false",
            max_battery,
            current_battery,
            handle->device->default_music_folder,
            handle->device->default_playlist_folder,
            handle->device->default_picture_folder,
            handle->device->default_video_folder,
            handle->device->default_organizer_folder,
            handle->device->default_zencast_folder,
            handle->device->default_album_folder,
            handle->device->default_text_folder);

    if (manufacturer_raw != NULL) LIBMTP_FreeMemory(manufacturer_raw);
    if (model_raw != NULL) LIBMTP_FreeMemory(model_raw);
    if (serial_raw != NULL) LIBMTP_FreeMemory(serial_raw);
    if (version_raw != NULL) LIBMTP_FreeMemory(version_raw);
    if (friendly_raw != NULL) LIBMTP_FreeMemory(friendly_raw);
    if (sync_raw != NULL) LIBMTP_FreeMemory(sync_raw);
    free(manufacturer); free(model); free(serial); free(version); free(friendly); free(sync);

    if (json == NULL) {
        mtp_bridge_set_error(handle, "Failed to allocate extended device information JSON");
    } else {
        mtp_bridge_set_error(handle, "");
    }
    pthread_mutex_unlock(&handle->mutex);
    return json;
}

int mtp_bridge_set_friendly_name(mtp_bridge_handle_t *handle, const char *name) {
    if (mtp_bridge_lock_connected(handle) != 0) {
        return -1;
    }
    LIBMTP_Clear_Errorstack(handle->device);
    int result = LIBMTP_Set_Friendlyname(handle->device, name == NULL ? "" : name);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to set MTP friendly name");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

int mtp_bridge_set_sync_partner(mtp_bridge_handle_t *handle, const char *partner) {
    if (mtp_bridge_lock_connected(handle) != 0) {
        return -1;
    }
    LIBMTP_Clear_Errorstack(handle->device);
    int result = LIBMTP_Set_Syncpartner(handle->device, partner == NULL ? "" : partner);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to set MTP sync partner");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

int mtp_bridge_get_battery_level(mtp_bridge_handle_t *handle, uint8_t *maximum, uint8_t *current) {
    if (maximum == NULL || current == NULL || mtp_bridge_lock_connected(handle) != 0) {
        return -1;
    }
    LIBMTP_Clear_Errorstack(handle->device);
    int result = LIBMTP_Get_Batterylevel(handle->device, maximum, current);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to read MTP battery level");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

char *mtp_bridge_secure_time(mtp_bridge_handle_t *handle) {
    if (mtp_bridge_lock_connected(handle) != 0) {
        return NULL;
    }
    char *value = NULL;
    LIBMTP_Clear_Errorstack(handle->device);
    if (LIBMTP_Get_Secure_Time(handle->device, &value) != 0) {
        mtp_bridge_set_error_from_errorstack(handle, "Failed to read MTP secure time");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return value;
}

char *mtp_bridge_device_certificate(mtp_bridge_handle_t *handle) {
    if (mtp_bridge_lock_connected(handle) != 0) {
        return NULL;
    }
    char *value = NULL;
    LIBMTP_Clear_Errorstack(handle->device);
    if (LIBMTP_Get_Device_Certificate(handle->device, &value) != 0) {
        mtp_bridge_set_error_from_errorstack(handle, "Failed to read MTP device certificate");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return value;
}

char *mtp_bridge_supported_filetypes_json(mtp_bridge_handle_t *handle) {
    if (mtp_bridge_lock_connected(handle) != 0) {
        return NULL;
    }
    uint16_t *types = NULL;
    uint16_t count = 0;
    LIBMTP_Clear_Errorstack(handle->device);
    if (LIBMTP_Get_Supported_Filetypes(handle->device, &types, &count) != 0) {
        mtp_bridge_set_error_from_errorstack(handle, "Failed to read supported file types");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    mtp_bridge_json_builder_t builder;
    if (mtp_bridge_json_builder_init(&builder, "{\"error\":null,\"data\":[") != 0) {
        if (types != NULL) LIBMTP_FreeMemory(types);
        mtp_bridge_set_error(handle, "Failed to allocate supported file types JSON");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    for (uint16_t i = 0; i < count; i++) {
        const char *description_raw = LIBMTP_Get_Filetype_Description((LIBMTP_filetype_t)types[i]);
        char *description = mtp_bridge_json_escape(description_raw);
        char *entry = description == NULL ? NULL : mtp_bridge_format_alloc(
            "%s{\"filetype\":%u,\"description\":\"%s\"}",
            i == 0 ? "" : ",",
            types[i],
            description);
        free(description);
        if (entry == NULL || mtp_bridge_json_builder_append(&builder, entry) != 0) {
            free(entry);
            mtp_bridge_json_builder_destroy(&builder);
            if (types != NULL) LIBMTP_FreeMemory(types);
            mtp_bridge_set_error(handle, "Failed to allocate supported file types JSON");
            pthread_mutex_unlock(&handle->mutex);
            return NULL;
        }
        free(entry);
    }
    if (types != NULL) LIBMTP_FreeMemory(types);
    char *json = mtp_bridge_take_json_or_error(handle, &builder, "Failed to allocate supported file types JSON");
    pthread_mutex_unlock(&handle->mutex);
    return json;
}

char *mtp_bridge_capabilities_json(mtp_bridge_handle_t *handle) {
    if (mtp_bridge_lock_connected(handle) != 0) {
        return NULL;
    }
    int partial_get = LIBMTP_Check_Capability(handle->device, LIBMTP_DEVICECAP_GetPartialObject);
    int partial_send = LIBMTP_Check_Capability(handle->device, LIBMTP_DEVICECAP_SendPartialObject);
    int edit = LIBMTP_Check_Capability(handle->device, LIBMTP_DEVICECAP_EditObjects);
    int move = LIBMTP_Check_Capability(handle->device, LIBMTP_DEVICECAP_MoveObject);
    int copy = LIBMTP_Check_Capability(handle->device, LIBMTP_DEVICECAP_CopyObject);
    char *json = mtp_bridge_format_alloc(
        "{\"error\":null,\"data\":{\"getPartialObject\":%s,\"sendPartialObject\":%s,\"editObjects\":%s,\"moveObject\":%s,\"copyObject\":%s}}",
        partial_get ? "true" : "false",
        partial_send ? "true" : "false",
        edit ? "true" : "false",
        move ? "true" : "false",
        copy ? "true" : "false");
    if (json == NULL) mtp_bridge_set_error(handle, "Failed to allocate capabilities JSON");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return json;
}

int mtp_bridge_refresh_storage(mtp_bridge_handle_t *handle, int sort_mode) {
    if (mtp_bridge_lock_connected(handle) != 0) {
        return -1;
    }
    LIBMTP_Clear_Errorstack(handle->device);
    int result = LIBMTP_Get_Storage(handle->device, sort_mode);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to refresh MTP storage");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

int mtp_bridge_format_storage(mtp_bridge_handle_t *handle, uint32_t storage_id) {
    if (mtp_bridge_lock_connected(handle) != 0) {
        return -1;
    }
    if (LIBMTP_Get_Storage(handle->device, LIBMTP_STORAGE_SORTBY_NOTSORTED) < 0) {
        mtp_bridge_set_error_from_errorstack(handle, "Failed to read MTP storage list");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    LIBMTP_devicestorage_t *target = NULL;
    for (LIBMTP_devicestorage_t *storage = handle->device->storage; storage != NULL; storage = storage->next) {
        if (storage->id == storage_id) {
            target = storage;
            break;
        }
    }
    if (target == NULL) {
        mtp_bridge_set_error(handle, "MTP storage was not found");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    LIBMTP_Clear_Errorstack(handle->device);
    int result = LIBMTP_Format_Storage(handle->device, target);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to format MTP storage");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

char *mtp_bridge_filelisting_json(mtp_bridge_handle_t *handle) {
    if (mtp_bridge_lock_connected(handle) != 0) {
        return NULL;
    }
    LIBMTP_Clear_Errorstack(handle->device);
    LIBMTP_file_t *files = LIBMTP_Get_Filelisting(handle->device);
    if (files == NULL && mtp_bridge_set_error_from_errorstack_if_present(handle, "Failed to read MTP file listing")) {
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    mtp_bridge_json_builder_t builder;
    if (mtp_bridge_json_builder_init(&builder, "{\"error\":null,\"data\":[") != 0) {
        mtp_bridge_destroy_file_list(files);
        mtp_bridge_set_error(handle, "Failed to allocate MTP file listing JSON");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    int first = 1;
    for (LIBMTP_file_t *file = files; file != NULL; file = file->next) {
        if (mtp_bridge_append_file_metadata(&builder, file, first ? "" : ",") != 0) {
            mtp_bridge_json_builder_destroy(&builder);
            mtp_bridge_destroy_file_list(files);
            mtp_bridge_set_error(handle, "Failed to allocate MTP file listing JSON");
            pthread_mutex_unlock(&handle->mutex);
            return NULL;
        }
        first = 0;
    }
    mtp_bridge_destroy_file_list(files);
    char *json = mtp_bridge_take_json_or_error(handle, &builder, "Failed to allocate MTP file listing JSON");
    pthread_mutex_unlock(&handle->mutex);
    return json;
}

char *mtp_bridge_children_json(mtp_bridge_handle_t *handle, uint32_t storage_id, uint32_t parent_id) {
    if (mtp_bridge_lock_connected(handle) != 0) {
        return NULL;
    }
    uint32_t *children = NULL;
    LIBMTP_Clear_Errorstack(handle->device);
    int child_count = LIBMTP_Get_Children(handle->device, storage_id, parent_id, &children);
    if (child_count < 0) {
        mtp_bridge_set_error_from_errorstack(handle, "Failed to read MTP children");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    mtp_bridge_json_builder_t builder;
    if (mtp_bridge_json_builder_init(&builder, "{\"error\":null,\"data\":") != 0
        || mtp_bridge_append_u32_array(&builder, children, (uint32_t)child_count) != 0
        || mtp_bridge_json_builder_append(&builder, "}") != 0) {
        mtp_bridge_json_builder_destroy(&builder);
        if (children != NULL) LIBMTP_FreeMemory(children);
        mtp_bridge_set_error(handle, "Failed to allocate MTP children JSON");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    if (children != NULL) LIBMTP_FreeMemory(children);
    mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return builder.data;
}

char *mtp_bridge_file_metadata_json(mtp_bridge_handle_t *handle, uint32_t object_id) {
    if (mtp_bridge_lock_connected(handle) != 0) {
        return NULL;
    }
    LIBMTP_Clear_Errorstack(handle->device);
    LIBMTP_file_t *file = LIBMTP_Get_Filemetadata(handle->device, object_id);
    if (file == NULL) {
        mtp_bridge_set_error_from_errorstack(handle, "Failed to read MTP file metadata");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    mtp_bridge_json_builder_t builder;
    if (mtp_bridge_json_builder_init(&builder, "{\"error\":null,\"data\":") != 0
        || mtp_bridge_append_file_metadata(&builder, file, "") != 0
        || mtp_bridge_json_builder_append(&builder, "}") != 0) {
        mtp_bridge_json_builder_destroy(&builder);
        LIBMTP_destroy_file_t(file);
        mtp_bridge_set_error(handle, "Failed to allocate MTP file metadata JSON");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    LIBMTP_destroy_file_t(file);
    mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return builder.data;
}

int mtp_bridge_delete_object(mtp_bridge_handle_t *handle, uint32_t object_id) {
    if (mtp_bridge_lock_connected(handle) != 0) return -1;
    int result = mtp_bridge_delete_object_locked(handle, object_id, "Failed to delete MTP object");
    if (result == 0) mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

int mtp_bridge_move_object(mtp_bridge_handle_t *handle, uint32_t object_id, uint32_t storage_id, uint32_t parent_id) {
    if (mtp_bridge_lock_connected(handle) != 0) return -1;
    LIBMTP_Clear_Errorstack(handle->device);
    int result = LIBMTP_Move_Object(handle->device, object_id, storage_id, parent_id);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to move MTP object");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

int mtp_bridge_copy_object(mtp_bridge_handle_t *handle, uint32_t object_id, uint32_t storage_id, uint32_t parent_id) {
    if (mtp_bridge_lock_connected(handle) != 0) return -1;
    LIBMTP_Clear_Errorstack(handle->device);
    int result = LIBMTP_Copy_Object(handle->device, object_id, storage_id, parent_id);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to copy MTP object");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

int mtp_bridge_set_object_filename(mtp_bridge_handle_t *handle, uint32_t object_id, const char *name) {
    if (name == NULL || name[0] == '\0') return -1;
    if (mtp_bridge_lock_connected(handle) != 0) return -1;
    int result = mtp_bridge_rename_object_locked(handle, object_id, name, "Failed to set MTP object filename");
    if (result == 0) mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

char *mtp_bridge_get_object_string(mtp_bridge_handle_t *handle, uint32_t object_id, int property) {
    if (mtp_bridge_lock_connected(handle) != 0) return NULL;
    LIBMTP_Clear_Errorstack(handle->device);
    char *value = LIBMTP_Get_String_From_Object(handle->device, object_id, (LIBMTP_property_t)property);
    if (value == NULL) mtp_bridge_set_error_from_errorstack(handle, "Failed to read MTP object string property");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return value;
}

uint64_t mtp_bridge_get_object_u64(mtp_bridge_handle_t *handle, uint32_t object_id, int property, uint64_t fallback) {
    if (mtp_bridge_lock_connected(handle) != 0) return fallback;
    uint64_t value = LIBMTP_Get_u64_From_Object(handle->device, object_id, (LIBMTP_property_t)property, fallback);
    pthread_mutex_unlock(&handle->mutex);
    return value;
}

uint32_t mtp_bridge_get_object_u32(mtp_bridge_handle_t *handle, uint32_t object_id, int property, uint32_t fallback) {
    if (mtp_bridge_lock_connected(handle) != 0) return fallback;
    uint32_t value = LIBMTP_Get_u32_From_Object(handle->device, object_id, (LIBMTP_property_t)property, fallback);
    pthread_mutex_unlock(&handle->mutex);
    return value;
}

uint16_t mtp_bridge_get_object_u16(mtp_bridge_handle_t *handle, uint32_t object_id, int property, uint16_t fallback) {
    if (mtp_bridge_lock_connected(handle) != 0) return fallback;
    uint16_t value = LIBMTP_Get_u16_From_Object(handle->device, object_id, (LIBMTP_property_t)property, fallback);
    pthread_mutex_unlock(&handle->mutex);
    return value;
}

uint8_t mtp_bridge_get_object_u8(mtp_bridge_handle_t *handle, uint32_t object_id, int property, uint8_t fallback) {
    if (mtp_bridge_lock_connected(handle) != 0) return fallback;
    uint8_t value = LIBMTP_Get_u8_From_Object(handle->device, object_id, (LIBMTP_property_t)property, fallback);
    pthread_mutex_unlock(&handle->mutex);
    return value;
}

int mtp_bridge_set_object_string(mtp_bridge_handle_t *handle, uint32_t object_id, int property, const char *value) {
    if (mtp_bridge_lock_connected(handle) != 0) return -1;
    LIBMTP_Clear_Errorstack(handle->device);
    int result = LIBMTP_Set_Object_String(handle->device, object_id, (LIBMTP_property_t)property, value == NULL ? "" : value);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to set MTP object string property");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

int mtp_bridge_set_object_u32(mtp_bridge_handle_t *handle, uint32_t object_id, int property, uint32_t value) {
    if (mtp_bridge_lock_connected(handle) != 0) return -1;
    LIBMTP_Clear_Errorstack(handle->device);
    int result = LIBMTP_Set_Object_u32(handle->device, object_id, (LIBMTP_property_t)property, value);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to set MTP object u32 property");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

int mtp_bridge_set_object_u16(mtp_bridge_handle_t *handle, uint32_t object_id, int property, uint16_t value) {
    if (mtp_bridge_lock_connected(handle) != 0) return -1;
    LIBMTP_Clear_Errorstack(handle->device);
    int result = LIBMTP_Set_Object_u16(handle->device, object_id, (LIBMTP_property_t)property, value);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to set MTP object u16 property");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

int mtp_bridge_set_object_u8(mtp_bridge_handle_t *handle, uint32_t object_id, int property, uint8_t value) {
    if (mtp_bridge_lock_connected(handle) != 0) return -1;
    LIBMTP_Clear_Errorstack(handle->device);
    int result = LIBMTP_Set_Object_u8(handle->device, object_id, (LIBMTP_property_t)property, value);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to set MTP object u8 property");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

const char *mtp_bridge_property_description(int property) {
    return LIBMTP_Get_Property_Description((LIBMTP_property_t)property);
}

const char *mtp_bridge_filetype_description(int filetype) {
    return LIBMTP_Get_Filetype_Description((LIBMTP_filetype_t)filetype);
}

int mtp_bridge_is_property_supported(mtp_bridge_handle_t *handle, int property, int filetype) {
    if (mtp_bridge_lock_connected(handle) != 0) return -1;
    int result = LIBMTP_Is_Property_Supported(handle->device, (LIBMTP_property_t)property, (LIBMTP_filetype_t)filetype);
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

char *mtp_bridge_allowed_property_values_json(mtp_bridge_handle_t *handle, int property, int filetype) {
    if (mtp_bridge_lock_connected(handle) != 0) return NULL;
    LIBMTP_allowed_values_t values;
    memset(&values, 0, sizeof(values));
    LIBMTP_Clear_Errorstack(handle->device);
    if (LIBMTP_Get_Allowed_Property_Values(
            handle->device,
            (LIBMTP_property_t)property,
            (LIBMTP_filetype_t)filetype,
            &values) != 0) {
        mtp_bridge_set_error_from_errorstack(handle, "Failed to read allowed MTP property values");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }

    mtp_bridge_json_builder_t builder;
    if (mtp_bridge_json_builder_init(&builder, "{\"error\":null,\"data\":{\"datatype\":") != 0) {
        LIBMTP_destroy_allowed_values_t(&values);
        mtp_bridge_set_error(handle, "Failed to allocate allowed property values JSON");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    char *head = mtp_bridge_format_alloc("%d,\"isRange\":%s,\"numEntries\":%u,\"min\":", values.datatype, values.is_range ? "true" : "false", values.num_entries);
    if (head == NULL || mtp_bridge_json_builder_append(&builder, head) != 0) {
        free(head);
        mtp_bridge_json_builder_destroy(&builder);
        LIBMTP_destroy_allowed_values_t(&values);
        mtp_bridge_set_error(handle, "Failed to allocate allowed property values JSON");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    free(head);

    uint64_t min_value = 0;
    uint64_t max_value = 0;
    uint64_t step_value = 0;
    switch (values.datatype) {
        case LIBMTP_DATATYPE_UINT8: min_value = values.u8min; max_value = values.u8max; step_value = values.u8step; break;
        case LIBMTP_DATATYPE_INT8: min_value = (uint64_t)values.i8min; max_value = (uint64_t)values.i8max; step_value = (uint64_t)values.i8step; break;
        case LIBMTP_DATATYPE_UINT16: min_value = values.u16min; max_value = values.u16max; step_value = values.u16step; break;
        case LIBMTP_DATATYPE_INT16: min_value = (uint64_t)values.i16min; max_value = (uint64_t)values.i16max; step_value = (uint64_t)values.i16step; break;
        case LIBMTP_DATATYPE_UINT32: min_value = values.u32min; max_value = values.u32max; step_value = values.u32step; break;
        case LIBMTP_DATATYPE_INT32: min_value = (uint64_t)values.i32min; max_value = (uint64_t)values.i32max; step_value = (uint64_t)values.i32step; break;
        case LIBMTP_DATATYPE_UINT64: min_value = values.u64min; max_value = values.u64max; step_value = values.u64step; break;
        case LIBMTP_DATATYPE_INT64: min_value = (uint64_t)values.i64min; max_value = (uint64_t)values.i64max; step_value = (uint64_t)values.i64step; break;
    }
    char *range = mtp_bridge_format_alloc("%llu,\"max\":%llu,\"step\":%llu,\"values\":[", (unsigned long long)min_value, (unsigned long long)max_value, (unsigned long long)step_value);
    if (range == NULL || mtp_bridge_json_builder_append(&builder, range) != 0) {
        free(range);
        mtp_bridge_json_builder_destroy(&builder);
        LIBMTP_destroy_allowed_values_t(&values);
        mtp_bridge_set_error(handle, "Failed to allocate allowed property values JSON");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    free(range);
    for (uint16_t i = 0; i < values.num_entries; i++) {
        uint64_t entry_value = 0;
        switch (values.datatype) {
            case LIBMTP_DATATYPE_UINT8: entry_value = values.u8vals == NULL ? 0 : values.u8vals[i]; break;
            case LIBMTP_DATATYPE_INT8: entry_value = values.i8vals == NULL ? 0 : (uint64_t)values.i8vals[i]; break;
            case LIBMTP_DATATYPE_UINT16: entry_value = values.u16vals == NULL ? 0 : values.u16vals[i]; break;
            case LIBMTP_DATATYPE_INT16: entry_value = values.i16vals == NULL ? 0 : (uint64_t)values.i16vals[i]; break;
            case LIBMTP_DATATYPE_UINT32: entry_value = values.u32vals == NULL ? 0 : values.u32vals[i]; break;
            case LIBMTP_DATATYPE_INT32: entry_value = values.i32vals == NULL ? 0 : (uint64_t)values.i32vals[i]; break;
            case LIBMTP_DATATYPE_UINT64: entry_value = values.u64vals == NULL ? 0 : values.u64vals[i]; break;
            case LIBMTP_DATATYPE_INT64: entry_value = values.i64vals == NULL ? 0 : (uint64_t)values.i64vals[i]; break;
        }
        char *entry = mtp_bridge_format_alloc("%s%llu", i == 0 ? "" : ",", (unsigned long long)entry_value);
        if (entry == NULL || mtp_bridge_json_builder_append(&builder, entry) != 0) {
            free(entry);
            mtp_bridge_json_builder_destroy(&builder);
            LIBMTP_destroy_allowed_values_t(&values);
            mtp_bridge_set_error(handle, "Failed to allocate allowed property values JSON");
            pthread_mutex_unlock(&handle->mutex);
            return NULL;
        }
        free(entry);
    }
    LIBMTP_destroy_allowed_values_t(&values);
    if (mtp_bridge_json_builder_append(&builder, "]}}") != 0) {
        mtp_bridge_json_builder_destroy(&builder);
        mtp_bridge_set_error(handle, "Failed to allocate allowed property values JSON");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return builder.data;
}

int mtp_bridge_get_thumbnail(mtp_bridge_handle_t *handle, uint32_t object_id, unsigned char **data, uint32_t *size) {
    if (data == NULL || size == NULL || mtp_bridge_lock_connected(handle) != 0) return -1;
    unsigned int raw_size = 0;
    LIBMTP_Clear_Errorstack(handle->device);
    int result = LIBMTP_Get_Thumbnail(handle->device, object_id, data, &raw_size);
    *size = raw_size;
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to read MTP thumbnail");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

char *mtp_bridge_representative_sample_format_json(mtp_bridge_handle_t *handle, int filetype) {
    if (mtp_bridge_lock_connected(handle) != 0) return NULL;
    LIBMTP_filesampledata_t *sample = NULL;
    LIBMTP_Clear_Errorstack(handle->device);
    if (LIBMTP_Get_Representative_Sample_Format(handle->device, (LIBMTP_filetype_t)filetype, &sample) != 0 || sample == NULL) {
        mtp_bridge_set_error_from_errorstack(handle, "Failed to read representative sample format");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    char *json = mtp_bridge_format_alloc(
        "{\"error\":null,\"data\":{\"width\":%u,\"height\":%u,\"duration\":%u,\"filetype\":%d,\"size\":%llu}}",
        sample->width,
        sample->height,
        sample->duration,
        sample->filetype,
        (unsigned long long)sample->size);
    LIBMTP_destroy_filesampledata_t(sample);
    if (json == NULL) mtp_bridge_set_error(handle, "Failed to allocate representative sample JSON");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return json;
}

int mtp_bridge_get_representative_sample(mtp_bridge_handle_t *handle, uint32_t object_id, unsigned char **data, uint64_t *size) {
    if (data == NULL || size == NULL || mtp_bridge_lock_connected(handle) != 0) return -1;
    LIBMTP_filesampledata_t *sample = LIBMTP_new_filesampledata_t();
    if (sample == NULL) {
        mtp_bridge_set_error(handle, "Failed to allocate representative sample data");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    LIBMTP_Clear_Errorstack(handle->device);
    int result = LIBMTP_Get_Representative_Sample(handle->device, object_id, sample);
    if (result != 0) {
        LIBMTP_destroy_filesampledata_t(sample);
        mtp_bridge_set_error_from_errorstack(handle, "Failed to read representative sample");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    *size = sample->size;
    *data = (unsigned char *)sample->data;
    sample->data = NULL;
    LIBMTP_destroy_filesampledata_t(sample);
    mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return 0;
}

int mtp_bridge_send_representative_sample(mtp_bridge_handle_t *handle, uint32_t object_id, const unsigned char *data, uint64_t size, uint32_t width, uint32_t height, uint32_t duration, int filetype) {
    if (data == NULL || mtp_bridge_lock_connected(handle) != 0) return -1;
    LIBMTP_filesampledata_t *sample = LIBMTP_new_filesampledata_t();
    if (sample == NULL) {
        mtp_bridge_set_error(handle, "Failed to allocate representative sample data");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    sample->width = width;
    sample->height = height;
    sample->duration = duration;
    sample->filetype = (LIBMTP_filetype_t)filetype;
    sample->size = size;
    sample->data = (char *)data;
    LIBMTP_Clear_Errorstack(handle->device);
    int result = LIBMTP_Send_Representative_Sample(handle->device, object_id, sample);
    sample->data = NULL;
    LIBMTP_destroy_filesampledata_t(sample);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to send representative sample");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

int mtp_bridge_get_partial_object(mtp_bridge_handle_t *handle, uint32_t object_id, uint64_t offset, uint32_t max_bytes, unsigned char **data, uint32_t *size) {
    if (data == NULL || size == NULL || mtp_bridge_lock_connected(handle) != 0) return -1;
    unsigned int raw_size = 0;
    LIBMTP_Clear_Errorstack(handle->device);
    int result = LIBMTP_GetPartialObject(handle->device, object_id, offset, max_bytes, data, &raw_size);
    *size = raw_size;
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to read partial MTP object");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

int mtp_bridge_send_partial_object(mtp_bridge_handle_t *handle, uint32_t object_id, uint64_t offset, const unsigned char *data, uint32_t size) {
    if (data == NULL || mtp_bridge_lock_connected(handle) != 0) return -1;
    LIBMTP_Clear_Errorstack(handle->device);
    int result = LIBMTP_SendPartialObject(handle->device, object_id, offset, (unsigned char *)data, size);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to send partial MTP object");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

int mtp_bridge_begin_edit_object(mtp_bridge_handle_t *handle, uint32_t object_id) {
    if (mtp_bridge_lock_connected(handle) != 0) return -1;
    int result = LIBMTP_BeginEditObject(handle->device, object_id);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to begin MTP object edit");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

int mtp_bridge_end_edit_object(mtp_bridge_handle_t *handle, uint32_t object_id) {
    if (mtp_bridge_lock_connected(handle) != 0) return -1;
    int result = LIBMTP_EndEditObject(handle->device, object_id);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to end MTP object edit");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

int mtp_bridge_truncate_object(mtp_bridge_handle_t *handle, uint32_t object_id, uint64_t size) {
    if (mtp_bridge_lock_connected(handle) != 0) return -1;
    int result = LIBMTP_TruncateObject(handle->device, object_id, size);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to truncate MTP object");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

int mtp_bridge_download_file_by_id(mtp_bridge_handle_t *handle, uint32_t object_id, const char *destination_path, mtp_bridge_progress_callback_t callback, void *context) {
    if (destination_path == NULL || destination_path[0] == '\0' || mtp_bridge_lock_connected(handle) != 0) return -1;
    mtp_bridge_transfer_context_t transfer = { .full_path = "", .name = "", .callback = callback, .context = context };
    LIBMTP_Clear_Errorstack(handle->device);
    int result = LIBMTP_Get_File_To_File(handle->device, object_id, destination_path, mtp_bridge_transfer_progress_callback, &transfer);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to download MTP file by id");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

int mtp_bridge_download_file_to_descriptor(mtp_bridge_handle_t *handle, uint32_t object_id, int fd, mtp_bridge_progress_callback_t callback, void *context) {
    if (mtp_bridge_lock_connected(handle) != 0) return -1;
    mtp_bridge_transfer_context_t transfer = { .full_path = "", .name = "", .callback = callback, .context = context };
    LIBMTP_Clear_Errorstack(handle->device);
    int result = LIBMTP_Get_File_To_File_Descriptor(handle->device, object_id, fd, mtp_bridge_transfer_progress_callback, &transfer);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to download MTP file to descriptor");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

typedef struct {
    mtp_bridge_data_callback_t callback;
    void *context;
} mtp_bridge_data_put_context_t;

static uint16_t mtp_bridge_data_put_callback(void *params, void *priv, uint32_t sendlen, unsigned char *data, uint32_t *putlen) {
    (void)params;
    mtp_bridge_data_put_context_t *context = priv;
    if (context == NULL || context->callback == NULL) {
        *putlen = sendlen;
        return LIBMTP_HANDLER_RETURN_OK;
    }
    context->callback(data, sendlen, context->context);
    *putlen = sendlen;
    return LIBMTP_HANDLER_RETURN_OK;
}

typedef struct {
    mtp_bridge_data_request_callback_t callback;
    void *context;
} mtp_bridge_data_get_context_t;

static uint16_t mtp_bridge_data_get_callback(void *params, void *priv, uint32_t wantlen, unsigned char *data, uint32_t *gotlen) {
    (void)params;
    mtp_bridge_data_get_context_t *context = priv;
    if (context == NULL || context->callback == NULL) {
        *gotlen = 0;
        return LIBMTP_HANDLER_RETURN_ERROR;
    }
    return context->callback(data, wantlen, gotlen, context->context) == 0
        ? LIBMTP_HANDLER_RETURN_OK
        : LIBMTP_HANDLER_RETURN_ERROR;
}

int mtp_bridge_download_file_to_handler(mtp_bridge_handle_t *handle, uint32_t object_id, mtp_bridge_data_callback_t data_callback, void *data_context, mtp_bridge_progress_callback_t progress_callback, void *progress_context) {
    if (mtp_bridge_lock_connected(handle) != 0) return -1;
    mtp_bridge_data_put_context_t data = { .callback = data_callback, .context = data_context };
    mtp_bridge_transfer_context_t transfer = { .full_path = "", .name = "", .callback = progress_callback, .context = progress_context };
    LIBMTP_Clear_Errorstack(handle->device);
    int result = LIBMTP_Get_File_To_Handler(handle->device, object_id, mtp_bridge_data_put_callback, &data, mtp_bridge_transfer_progress_callback, &transfer);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to download MTP file to handler");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

int mtp_bridge_upload_file_to_parent(mtp_bridge_handle_t *handle, uint32_t storage_id, uint32_t parent_id, const char *source_path, const char *name, int filetype, mtp_bridge_progress_callback_t callback, void *context) {
    if (source_path == NULL || source_path[0] == '\0' || mtp_bridge_lock_connected(handle) != 0) return -1;
    const char *effective_name = (name == NULL || name[0] == '\0') ? mtp_bridge_basename(source_path) : name;
    struct stat source_stat;
    if (stat(source_path, &source_stat) != 0 || !S_ISREG(source_stat.st_mode)) {
        mtp_bridge_set_error(handle, "MTP upload source must be a readable regular file");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    LIBMTP_file_t *metadata = LIBMTP_new_file_t();
    if (metadata == NULL) {
        mtp_bridge_set_error(handle, "Failed to allocate MTP file metadata");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    metadata->filename = strdup(effective_name);
    metadata->filesize = (uint64_t)source_stat.st_size;
    metadata->parent_id = parent_id;
    metadata->storage_id = storage_id;
    metadata->modificationdate = source_stat.st_mtime;
    metadata->filetype = (LIBMTP_filetype_t)filetype;
    if (metadata->filename == NULL) {
        LIBMTP_destroy_file_t(metadata);
        mtp_bridge_set_error(handle, "Failed to allocate MTP file name");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    mtp_bridge_transfer_context_t transfer = { .full_path = source_path, .name = effective_name, .callback = callback, .context = context };
    LIBMTP_Clear_Errorstack(handle->device);
    int result = LIBMTP_Send_File_From_File(handle->device, source_path, metadata, mtp_bridge_transfer_progress_callback, &transfer);
    LIBMTP_destroy_file_t(metadata);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to upload MTP file to parent");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

static LIBMTP_file_t *mtp_bridge_new_file_metadata(const char *name, uint64_t filesize, uint32_t storage_id, uint32_t parent_id, int filetype, time_t modificationdate) {
    LIBMTP_file_t *metadata = LIBMTP_new_file_t();
    if (metadata == NULL) {
        return NULL;
    }
    metadata->filename = strdup(name == NULL ? "" : name);
    if (metadata->filename == NULL) {
        LIBMTP_destroy_file_t(metadata);
        return NULL;
    }
    metadata->filesize = filesize;
    metadata->parent_id = parent_id;
    metadata->storage_id = storage_id;
    metadata->modificationdate = modificationdate;
    metadata->filetype = (LIBMTP_filetype_t)filetype;
    return metadata;
}

int mtp_bridge_upload_file_from_descriptor(mtp_bridge_handle_t *handle, uint32_t storage_id, uint32_t parent_id, int fd, const char *name, uint64_t filesize, int filetype, mtp_bridge_progress_callback_t callback, void *context) {
    if (name == NULL || name[0] == '\0' || mtp_bridge_lock_connected(handle) != 0) return -1;
    LIBMTP_file_t *metadata = mtp_bridge_new_file_metadata(name, filesize, storage_id, parent_id, filetype, time(NULL));
    if (metadata == NULL) {
        mtp_bridge_set_error(handle, "Failed to allocate MTP file metadata");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    mtp_bridge_transfer_context_t transfer = { .full_path = "", .name = name, .callback = callback, .context = context };
    LIBMTP_Clear_Errorstack(handle->device);
    int result = LIBMTP_Send_File_From_File_Descriptor(handle->device, fd, metadata, mtp_bridge_transfer_progress_callback, &transfer);
    LIBMTP_destroy_file_t(metadata);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to upload MTP file from descriptor");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

int mtp_bridge_upload_file_from_handler(mtp_bridge_handle_t *handle, uint32_t storage_id, uint32_t parent_id, const char *name, uint64_t filesize, int filetype, mtp_bridge_data_request_callback_t data_callback, void *data_context, mtp_bridge_progress_callback_t progress_callback, void *progress_context) {
    if (name == NULL || data_callback == NULL || mtp_bridge_lock_connected(handle) != 0) return -1;
    LIBMTP_file_t *metadata = mtp_bridge_new_file_metadata(name, filesize, storage_id, parent_id, filetype, time(NULL));
    if (metadata == NULL) {
        mtp_bridge_set_error(handle, "Failed to allocate MTP file metadata");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    mtp_bridge_data_get_context_t data = { .callback = data_callback, .context = data_context };
    mtp_bridge_transfer_context_t transfer = { .full_path = "", .name = name, .callback = progress_callback, .context = progress_context };
    LIBMTP_Clear_Errorstack(handle->device);
    int result = LIBMTP_Send_File_From_Handler(handle->device, mtp_bridge_data_get_callback, &data, metadata, mtp_bridge_transfer_progress_callback, &transfer);
    LIBMTP_destroy_file_t(metadata);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to upload MTP file from handler");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

static char *mtp_bridge_track_list_json_locked(mtp_bridge_handle_t *handle, LIBMTP_track_t *tracks) {
    mtp_bridge_json_builder_t builder;
    if (mtp_bridge_json_builder_init(&builder, "{\"error\":null,\"data\":[") != 0) {
        return NULL;
    }
    int first = 1;
    for (LIBMTP_track_t *track = tracks; track != NULL; track = track->next) {
        if (mtp_bridge_append_track_metadata(&builder, track, first ? "" : ",") != 0) {
            mtp_bridge_json_builder_destroy(&builder);
            return NULL;
        }
        first = 0;
    }
    return mtp_bridge_take_json_or_error(handle, &builder, "Failed to allocate MTP track JSON");
}

char *mtp_bridge_tracklisting_json(mtp_bridge_handle_t *handle) {
    if (mtp_bridge_lock_connected(handle) != 0) return NULL;
    LIBMTP_Clear_Errorstack(handle->device);
    LIBMTP_track_t *tracks = LIBMTP_Get_Tracklisting(handle->device);
    if (tracks == NULL && mtp_bridge_set_error_from_errorstack_if_present(handle, "Failed to read MTP track list")) {
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    char *json = mtp_bridge_track_list_json_locked(handle, tracks);
    mtp_bridge_destroy_track_list(tracks);
    if (json == NULL) mtp_bridge_set_error(handle, "Failed to allocate MTP track JSON");
    pthread_mutex_unlock(&handle->mutex);
    return json;
}

char *mtp_bridge_tracklisting_for_storage_json(mtp_bridge_handle_t *handle, uint32_t storage_id) {
    if (mtp_bridge_lock_connected(handle) != 0) return NULL;
    LIBMTP_Clear_Errorstack(handle->device);
    LIBMTP_track_t *tracks = LIBMTP_Get_Tracklisting_With_Callback_For_Storage(handle->device, storage_id, NULL, NULL);
    if (tracks == NULL && mtp_bridge_set_error_from_errorstack_if_present(handle, "Failed to read MTP track list")) {
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    char *json = mtp_bridge_track_list_json_locked(handle, tracks);
    mtp_bridge_destroy_track_list(tracks);
    if (json == NULL) mtp_bridge_set_error(handle, "Failed to allocate MTP track JSON");
    pthread_mutex_unlock(&handle->mutex);
    return json;
}

char *mtp_bridge_track_metadata_json(mtp_bridge_handle_t *handle, uint32_t track_id) {
    if (mtp_bridge_lock_connected(handle) != 0) return NULL;
    LIBMTP_track_t *track = LIBMTP_Get_Trackmetadata(handle->device, track_id);
    if (track == NULL) {
        mtp_bridge_set_error_from_errorstack(handle, "Failed to read MTP track metadata");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    mtp_bridge_json_builder_t builder;
    if (mtp_bridge_json_builder_init(&builder, "{\"error\":null,\"data\":") != 0
        || mtp_bridge_append_track_metadata(&builder, track, "") != 0
        || mtp_bridge_json_builder_append(&builder, "}") != 0) {
        mtp_bridge_json_builder_destroy(&builder);
        LIBMTP_destroy_track_t(track);
        mtp_bridge_set_error(handle, "Failed to allocate MTP track JSON");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    LIBMTP_destroy_track_t(track);
    mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return builder.data;
}

int mtp_bridge_track_exists(mtp_bridge_handle_t *handle, uint32_t track_id) {
    if (mtp_bridge_lock_connected(handle) != 0) return -1;
    int result = LIBMTP_Track_Exists(handle->device, track_id);
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

int mtp_bridge_set_track_name(mtp_bridge_handle_t *handle, uint32_t track_id, const char *name) {
    if (name == NULL || mtp_bridge_lock_connected(handle) != 0) return -1;
    LIBMTP_track_t *track = LIBMTP_Get_Trackmetadata(handle->device, track_id);
    if (track == NULL) {
        mtp_bridge_set_error_from_errorstack(handle, "Failed to read MTP track metadata");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    int result = LIBMTP_Set_Track_Name(handle->device, track, name);
    LIBMTP_destroy_track_t(track);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to set MTP track name");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

static int mtp_bridge_replace_string(char **target, const char *value) {
    if (value == NULL) return 0;
    char *copy = strdup(value);
    if (copy == NULL) return -1;
    free(*target);
    *target = copy;
    return 0;
}

int mtp_bridge_update_track_metadata(mtp_bridge_handle_t *handle, uint32_t track_id, const char *title, const char *artist, const char *album, const char *genre, uint16_t track_number, uint16_t rating) {
    if (mtp_bridge_lock_connected(handle) != 0) return -1;
    LIBMTP_track_t *track = LIBMTP_Get_Trackmetadata(handle->device, track_id);
    if (track == NULL) {
        mtp_bridge_set_error_from_errorstack(handle, "Failed to read MTP track metadata");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    if (mtp_bridge_replace_string(&track->title, title) != 0
        || mtp_bridge_replace_string(&track->artist, artist) != 0
        || mtp_bridge_replace_string(&track->album, album) != 0
        || mtp_bridge_replace_string(&track->genre, genre) != 0) {
        LIBMTP_destroy_track_t(track);
        mtp_bridge_set_error(handle, "Failed to allocate MTP track metadata");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    if (track_number > 0) track->tracknumber = track_number;
    if (rating <= 100) track->rating = rating;
    int result = LIBMTP_Update_Track_Metadata(handle->device, track);
    LIBMTP_destroy_track_t(track);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to update MTP track metadata");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

int mtp_bridge_download_track_by_id(mtp_bridge_handle_t *handle, uint32_t track_id, const char *destination_path, mtp_bridge_progress_callback_t callback, void *context) {
    if (destination_path == NULL || mtp_bridge_lock_connected(handle) != 0) return -1;
    mtp_bridge_transfer_context_t transfer = { .full_path = "", .name = "", .callback = callback, .context = context };
    int result = LIBMTP_Get_Track_To_File(handle->device, track_id, destination_path, mtp_bridge_transfer_progress_callback, &transfer);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to download MTP track");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

int mtp_bridge_download_track_to_descriptor(mtp_bridge_handle_t *handle, uint32_t track_id, int fd, mtp_bridge_progress_callback_t callback, void *context) {
    if (mtp_bridge_lock_connected(handle) != 0) return -1;
    mtp_bridge_transfer_context_t transfer = { .full_path = "", .name = "", .callback = callback, .context = context };
    int result = LIBMTP_Get_Track_To_File_Descriptor(handle->device, track_id, fd, mtp_bridge_transfer_progress_callback, &transfer);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to download MTP track to descriptor");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

static LIBMTP_track_t *mtp_bridge_new_track_metadata(uint32_t storage_id, uint32_t parent_id, const char *filename, const char *title, const char *artist, const char *album, const char *genre, uint64_t filesize, int filetype, time_t modificationdate) {
    LIBMTP_track_t *track = LIBMTP_new_track_t();
    if (track == NULL) {
        return NULL;
    }
    track->storage_id = storage_id;
    track->parent_id = parent_id;
    track->filesize = filesize;
    track->filetype = (LIBMTP_filetype_t)filetype;
    track->modificationdate = modificationdate;
    if (mtp_bridge_replace_string(&track->filename, filename == NULL ? "" : filename) != 0
        || mtp_bridge_replace_string(&track->title, title == NULL ? "" : title) != 0
        || mtp_bridge_replace_string(&track->artist, artist == NULL ? "" : artist) != 0
        || mtp_bridge_replace_string(&track->album, album == NULL ? "" : album) != 0
        || mtp_bridge_replace_string(&track->genre, genre == NULL ? "" : genre) != 0) {
        LIBMTP_destroy_track_t(track);
        return NULL;
    }
    return track;
}

int mtp_bridge_upload_track_from_file(mtp_bridge_handle_t *handle, uint32_t storage_id, uint32_t parent_id, const char *source_path, const char *filename, const char *title, const char *artist, const char *album, const char *genre, int filetype, mtp_bridge_progress_callback_t callback, void *context) {
    if (source_path == NULL || source_path[0] == '\0' || mtp_bridge_lock_connected(handle) != 0) return -1;
    struct stat source_stat;
    if (stat(source_path, &source_stat) != 0 || !S_ISREG(source_stat.st_mode)) {
        mtp_bridge_set_error(handle, "MTP track upload source must be a readable regular file");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    const char *effective_filename = (filename == NULL || filename[0] == '\0') ? mtp_bridge_basename(source_path) : filename;
    LIBMTP_track_t *track = mtp_bridge_new_track_metadata(storage_id, parent_id, effective_filename, title, artist, album, genre, (uint64_t)source_stat.st_size, filetype, source_stat.st_mtime);
    if (track == NULL) {
        mtp_bridge_set_error(handle, "Failed to allocate MTP track metadata");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    mtp_bridge_transfer_context_t transfer = { .full_path = source_path, .name = effective_filename, .callback = callback, .context = context };
    int result = LIBMTP_Send_Track_From_File(handle->device, source_path, track, mtp_bridge_transfer_progress_callback, &transfer);
    LIBMTP_destroy_track_t(track);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to upload MTP track from file");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

int mtp_bridge_upload_track_from_descriptor(mtp_bridge_handle_t *handle, uint32_t storage_id, uint32_t parent_id, int fd, const char *filename, const char *title, const char *artist, const char *album, const char *genre, uint64_t filesize, int filetype, mtp_bridge_progress_callback_t callback, void *context) {
    if (filename == NULL || filename[0] == '\0' || mtp_bridge_lock_connected(handle) != 0) return -1;
    LIBMTP_track_t *track = mtp_bridge_new_track_metadata(storage_id, parent_id, filename, title, artist, album, genre, filesize, filetype, time(NULL));
    if (track == NULL) {
        mtp_bridge_set_error(handle, "Failed to allocate MTP track metadata");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    mtp_bridge_transfer_context_t transfer = { .full_path = "", .name = filename, .callback = callback, .context = context };
    int result = LIBMTP_Send_Track_From_File_Descriptor(handle->device, fd, track, mtp_bridge_transfer_progress_callback, &transfer);
    LIBMTP_destroy_track_t(track);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to upload MTP track from descriptor");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

int mtp_bridge_upload_track_from_handler(mtp_bridge_handle_t *handle, uint32_t storage_id, uint32_t parent_id, const char *filename, const char *title, const char *artist, const char *album, const char *genre, uint64_t filesize, int filetype, mtp_bridge_data_request_callback_t data_callback, void *data_context, mtp_bridge_progress_callback_t progress_callback, void *progress_context) {
    if (filename == NULL || data_callback == NULL || mtp_bridge_lock_connected(handle) != 0) return -1;
    LIBMTP_track_t *track = mtp_bridge_new_track_metadata(storage_id, parent_id, filename, title, artist, album, genre, filesize, filetype, time(NULL));
    if (track == NULL) {
        mtp_bridge_set_error(handle, "Failed to allocate MTP track metadata");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    mtp_bridge_data_get_context_t data = { .callback = data_callback, .context = data_context };
    mtp_bridge_transfer_context_t transfer = { .full_path = "", .name = filename, .callback = progress_callback, .context = progress_context };
    int result = LIBMTP_Send_Track_From_Handler(handle->device, mtp_bridge_data_get_callback, &data, track, mtp_bridge_transfer_progress_callback, &transfer);
    LIBMTP_destroy_track_t(track);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to upload MTP track from handler");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

static char *mtp_bridge_folder_list_json_locked(mtp_bridge_handle_t *handle, LIBMTP_folder_t *folders) {
    mtp_bridge_json_builder_t builder;
    if (mtp_bridge_json_builder_init(&builder, "{\"error\":null,\"data\":[") != 0) {
        return NULL;
    }
    int first = 1;
    if (mtp_bridge_append_folder_tree(&builder, folders, &first) != 0) {
        mtp_bridge_json_builder_destroy(&builder);
        return NULL;
    }
    return mtp_bridge_take_json_or_error(handle, &builder, "Failed to allocate MTP folder JSON");
}

char *mtp_bridge_folder_list_json(mtp_bridge_handle_t *handle) {
    if (mtp_bridge_lock_connected(handle) != 0) return NULL;
    LIBMTP_folder_t *folders = LIBMTP_Get_Folder_List(handle->device);
    if (folders == NULL && mtp_bridge_set_error_from_errorstack_if_present(handle, "Failed to read MTP folders")) {
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    char *json = mtp_bridge_folder_list_json_locked(handle, folders);
    LIBMTP_destroy_folder_t(folders);
    if (json == NULL) mtp_bridge_set_error(handle, "Failed to allocate MTP folder JSON");
    pthread_mutex_unlock(&handle->mutex);
    return json;
}

char *mtp_bridge_folder_list_for_storage_json(mtp_bridge_handle_t *handle, uint32_t storage_id) {
    if (mtp_bridge_lock_connected(handle) != 0) return NULL;
    LIBMTP_folder_t *folders = LIBMTP_Get_Folder_List_For_Storage(handle->device, storage_id);
    if (folders == NULL && mtp_bridge_set_error_from_errorstack_if_present(handle, "Failed to read MTP folders")) {
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    char *json = mtp_bridge_folder_list_json_locked(handle, folders);
    LIBMTP_destroy_folder_t(folders);
    if (json == NULL) mtp_bridge_set_error(handle, "Failed to allocate MTP folder JSON");
    pthread_mutex_unlock(&handle->mutex);
    return json;
}

int mtp_bridge_set_folder_name(mtp_bridge_handle_t *handle, uint32_t folder_id, const char *name) {
    if (name == NULL || mtp_bridge_lock_connected(handle) != 0) return -1;
    LIBMTP_folder_t *folders = LIBMTP_Get_Folder_List(handle->device);
    LIBMTP_folder_t *folder = LIBMTP_Find_Folder(folders, folder_id);
    if (folder == NULL) {
        LIBMTP_destroy_folder_t(folders);
        mtp_bridge_set_error(handle, "MTP folder was not found");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    int result = LIBMTP_Set_Folder_Name(handle->device, folder, name);
    LIBMTP_destroy_folder_t(folders);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to set MTP folder name");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

static char *mtp_bridge_playlist_list_json_locked(mtp_bridge_handle_t *handle, LIBMTP_playlist_t *playlists) {
    mtp_bridge_json_builder_t builder;
    if (mtp_bridge_json_builder_init(&builder, "{\"error\":null,\"data\":[") != 0) return NULL;
    int first = 1;
    for (LIBMTP_playlist_t *playlist = playlists; playlist != NULL; playlist = playlist->next) {
        if (mtp_bridge_append_playlist_metadata(&builder, playlist, first ? "" : ",") != 0) {
            mtp_bridge_json_builder_destroy(&builder);
            return NULL;
        }
        first = 0;
    }
    return mtp_bridge_take_json_or_error(handle, &builder, "Failed to allocate MTP playlist JSON");
}

char *mtp_bridge_playlist_list_json(mtp_bridge_handle_t *handle) {
    if (mtp_bridge_lock_connected(handle) != 0) return NULL;
    LIBMTP_playlist_t *playlists = LIBMTP_Get_Playlist_List(handle->device);
    if (playlists == NULL && mtp_bridge_set_error_from_errorstack_if_present(handle, "Failed to read MTP playlists")) {
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    char *json = mtp_bridge_playlist_list_json_locked(handle, playlists);
    mtp_bridge_destroy_playlist_list(playlists);
    if (json == NULL) mtp_bridge_set_error(handle, "Failed to allocate MTP playlist JSON");
    pthread_mutex_unlock(&handle->mutex);
    return json;
}

char *mtp_bridge_playlist_json(mtp_bridge_handle_t *handle, uint32_t playlist_id) {
    if (mtp_bridge_lock_connected(handle) != 0) return NULL;
    LIBMTP_playlist_t *playlist = LIBMTP_Get_Playlist(handle->device, playlist_id);
    if (playlist == NULL) {
        mtp_bridge_set_error_from_errorstack(handle, "Failed to read MTP playlist");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    mtp_bridge_json_builder_t builder;
    if (mtp_bridge_json_builder_init(&builder, "{\"error\":null,\"data\":") != 0
        || mtp_bridge_append_playlist_metadata(&builder, playlist, "") != 0
        || mtp_bridge_json_builder_append(&builder, "}") != 0) {
        mtp_bridge_json_builder_destroy(&builder);
        LIBMTP_destroy_playlist_t(playlist);
        mtp_bridge_set_error(handle, "Failed to allocate MTP playlist JSON");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    LIBMTP_destroy_playlist_t(playlist);
    mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return builder.data;
}

static int mtp_bridge_assign_tracks(uint32_t **target, uint32_t *count, const uint32_t *tracks, uint32_t track_count) {
    if (track_count == 0) {
        *target = NULL;
        *count = 0;
        return 0;
    }
    uint32_t *copy = malloc(sizeof(uint32_t) * track_count);
    if (copy == NULL) return -1;
    memcpy(copy, tracks, sizeof(uint32_t) * track_count);
    *target = copy;
    *count = track_count;
    return 0;
}

int mtp_bridge_create_playlist(mtp_bridge_handle_t *handle, uint32_t storage_id, uint32_t parent_id, const char *name, const uint32_t *tracks, uint32_t track_count) {
    if (name == NULL || (track_count > 0 && tracks == NULL) || mtp_bridge_lock_connected(handle) != 0) return -1;
    LIBMTP_playlist_t *playlist = LIBMTP_new_playlist_t();
    if (playlist == NULL || mtp_bridge_assign_tracks(&playlist->tracks, &playlist->no_tracks, tracks, track_count) != 0) {
        LIBMTP_destroy_playlist_t(playlist);
        mtp_bridge_set_error(handle, "Failed to allocate MTP playlist");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    playlist->name = strdup(name);
    playlist->storage_id = storage_id;
    playlist->parent_id = parent_id;
    int result = playlist->name == NULL ? -1 : LIBMTP_Create_New_Playlist(handle->device, playlist);
    LIBMTP_destroy_playlist_t(playlist);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to create MTP playlist");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

int mtp_bridge_update_playlist(mtp_bridge_handle_t *handle, uint32_t playlist_id, const char *name, const uint32_t *tracks, uint32_t track_count) {
    if ((track_count > 0 && tracks == NULL) || mtp_bridge_lock_connected(handle) != 0) return -1;
    LIBMTP_playlist_t *playlist = LIBMTP_Get_Playlist(handle->device, playlist_id);
    if (playlist == NULL) {
        mtp_bridge_set_error_from_errorstack(handle, "Failed to read MTP playlist");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    if (name != NULL && mtp_bridge_replace_string(&playlist->name, name) != 0) {
        LIBMTP_destroy_playlist_t(playlist);
        mtp_bridge_set_error(handle, "Failed to allocate MTP playlist name");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    if (tracks != NULL) {
        free(playlist->tracks);
        playlist->tracks = NULL;
        playlist->no_tracks = 0;
        if (mtp_bridge_assign_tracks(&playlist->tracks, &playlist->no_tracks, tracks, track_count) != 0) {
            LIBMTP_destroy_playlist_t(playlist);
            mtp_bridge_set_error(handle, "Failed to allocate MTP playlist tracks");
            pthread_mutex_unlock(&handle->mutex);
            return -1;
        }
    }
    int result = LIBMTP_Update_Playlist(handle->device, playlist);
    LIBMTP_destroy_playlist_t(playlist);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to update MTP playlist");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

int mtp_bridge_set_playlist_name(mtp_bridge_handle_t *handle, uint32_t playlist_id, const char *name) {
    if (name == NULL || mtp_bridge_lock_connected(handle) != 0) return -1;
    LIBMTP_playlist_t *playlist = LIBMTP_Get_Playlist(handle->device, playlist_id);
    if (playlist == NULL) {
        mtp_bridge_set_error_from_errorstack(handle, "Failed to read MTP playlist");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    int result = LIBMTP_Set_Playlist_Name(handle->device, playlist, name);
    LIBMTP_destroy_playlist_t(playlist);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to set MTP playlist name");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

static char *mtp_bridge_album_list_json_locked(mtp_bridge_handle_t *handle, LIBMTP_album_t *albums) {
    mtp_bridge_json_builder_t builder;
    if (mtp_bridge_json_builder_init(&builder, "{\"error\":null,\"data\":[") != 0) return NULL;
    int first = 1;
    for (LIBMTP_album_t *album = albums; album != NULL; album = album->next) {
        if (mtp_bridge_append_album_metadata(&builder, album, first ? "" : ",") != 0) {
            mtp_bridge_json_builder_destroy(&builder);
            return NULL;
        }
        first = 0;
    }
    return mtp_bridge_take_json_or_error(handle, &builder, "Failed to allocate MTP album JSON");
}

char *mtp_bridge_album_list_json(mtp_bridge_handle_t *handle) {
    if (mtp_bridge_lock_connected(handle) != 0) return NULL;
    LIBMTP_album_t *albums = LIBMTP_Get_Album_List(handle->device);
    if (albums == NULL && mtp_bridge_set_error_from_errorstack_if_present(handle, "Failed to read MTP albums")) {
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    char *json = mtp_bridge_album_list_json_locked(handle, albums);
    mtp_bridge_destroy_album_list(albums);
    if (json == NULL) mtp_bridge_set_error(handle, "Failed to allocate MTP album JSON");
    pthread_mutex_unlock(&handle->mutex);
    return json;
}

char *mtp_bridge_album_list_for_storage_json(mtp_bridge_handle_t *handle, uint32_t storage_id) {
    if (mtp_bridge_lock_connected(handle) != 0) return NULL;
    LIBMTP_album_t *albums = LIBMTP_Get_Album_List_For_Storage(handle->device, storage_id);
    if (albums == NULL && mtp_bridge_set_error_from_errorstack_if_present(handle, "Failed to read MTP albums")) {
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    char *json = mtp_bridge_album_list_json_locked(handle, albums);
    mtp_bridge_destroy_album_list(albums);
    if (json == NULL) mtp_bridge_set_error(handle, "Failed to allocate MTP album JSON");
    pthread_mutex_unlock(&handle->mutex);
    return json;
}

char *mtp_bridge_album_json(mtp_bridge_handle_t *handle, uint32_t album_id) {
    if (mtp_bridge_lock_connected(handle) != 0) return NULL;
    LIBMTP_album_t *album = LIBMTP_Get_Album(handle->device, album_id);
    if (album == NULL) {
        mtp_bridge_set_error_from_errorstack(handle, "Failed to read MTP album");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    mtp_bridge_json_builder_t builder;
    if (mtp_bridge_json_builder_init(&builder, "{\"error\":null,\"data\":") != 0
        || mtp_bridge_append_album_metadata(&builder, album, "") != 0
        || mtp_bridge_json_builder_append(&builder, "}") != 0) {
        mtp_bridge_json_builder_destroy(&builder);
        LIBMTP_destroy_album_t(album);
        mtp_bridge_set_error(handle, "Failed to allocate MTP album JSON");
        pthread_mutex_unlock(&handle->mutex);
        return NULL;
    }
    LIBMTP_destroy_album_t(album);
    mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return builder.data;
}

static int mtp_bridge_fill_album(LIBMTP_album_t *album, uint32_t storage_id, uint32_t parent_id, const char *name, const char *artist, const char *composer, const char *genre, const uint32_t *tracks, uint32_t track_count) {
    album->storage_id = storage_id;
    album->parent_id = parent_id;
    if (name != NULL && mtp_bridge_replace_string(&album->name, name) != 0) return -1;
    if (artist != NULL && mtp_bridge_replace_string(&album->artist, artist) != 0) return -1;
    if (composer != NULL && mtp_bridge_replace_string(&album->composer, composer) != 0) return -1;
    if (genre != NULL && mtp_bridge_replace_string(&album->genre, genre) != 0) return -1;
    if (tracks != NULL) {
        free(album->tracks);
        album->tracks = NULL;
        album->no_tracks = 0;
        if (mtp_bridge_assign_tracks(&album->tracks, &album->no_tracks, tracks, track_count) != 0) return -1;
    }
    return 0;
}

int mtp_bridge_create_album(mtp_bridge_handle_t *handle, uint32_t storage_id, uint32_t parent_id, const char *name, const char *artist, const char *composer, const char *genre, const uint32_t *tracks, uint32_t track_count) {
    if (name == NULL || (track_count > 0 && tracks == NULL) || mtp_bridge_lock_connected(handle) != 0) return -1;
    LIBMTP_album_t *album = LIBMTP_new_album_t();
    if (album == NULL || mtp_bridge_fill_album(album, storage_id, parent_id, name, artist, composer, genre, tracks, track_count) != 0) {
        LIBMTP_destroy_album_t(album);
        mtp_bridge_set_error(handle, "Failed to allocate MTP album");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    int result = LIBMTP_Create_New_Album(handle->device, album);
    LIBMTP_destroy_album_t(album);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to create MTP album");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

int mtp_bridge_update_album(mtp_bridge_handle_t *handle, uint32_t album_id, const char *name, const char *artist, const char *composer, const char *genre, const uint32_t *tracks, uint32_t track_count) {
    if ((track_count > 0 && tracks == NULL) || mtp_bridge_lock_connected(handle) != 0) return -1;
    LIBMTP_album_t *album = LIBMTP_Get_Album(handle->device, album_id);
    if (album == NULL) {
        mtp_bridge_set_error_from_errorstack(handle, "Failed to read MTP album");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    if (mtp_bridge_fill_album(album, album->storage_id, album->parent_id, name, artist, composer, genre, tracks, track_count) != 0) {
        LIBMTP_destroy_album_t(album);
        mtp_bridge_set_error(handle, "Failed to allocate MTP album metadata");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    int result = LIBMTP_Update_Album(handle->device, album);
    LIBMTP_destroy_album_t(album);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to update MTP album");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

int mtp_bridge_set_album_name(mtp_bridge_handle_t *handle, uint32_t album_id, const char *name) {
    if (name == NULL || mtp_bridge_lock_connected(handle) != 0) return -1;
    LIBMTP_album_t *album = LIBMTP_Get_Album(handle->device, album_id);
    if (album == NULL) {
        mtp_bridge_set_error_from_errorstack(handle, "Failed to read MTP album");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    int result = LIBMTP_Set_Album_Name(handle->device, album, name);
    LIBMTP_destroy_album_t(album);
    if (result != 0) mtp_bridge_set_error_from_errorstack(handle, "Failed to set MTP album name");
    else mtp_bridge_set_error(handle, "");
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

int mtp_bridge_read_event(mtp_bridge_handle_t *handle, int *event, uint32_t *parameter) {
    if (event == NULL || parameter == NULL || mtp_bridge_lock_connected(handle) != 0) return -1;
    LIBMTP_event_t raw_event = LIBMTP_EVENT_NONE;
    LIBMTP_Clear_Errorstack(handle->device);
    int result = LIBMTP_Read_Event(handle->device, &raw_event, parameter);
    if (result != 0) {
        mtp_bridge_set_error_from_errorstack(handle, "Failed to read MTP event");
    } else {
        *event = raw_event;
        mtp_bridge_set_error(handle, "");
    }
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

typedef struct {
    mtp_bridge_event_callback_t callback;
    void *context;
} mtp_bridge_event_context_t;

static void mtp_bridge_event_callback(int result, LIBMTP_event_t event, uint32_t parameter, void *data) {
    mtp_bridge_event_context_t *context = data;
    if (context != NULL && context->callback != NULL) {
        context->callback(result, event, parameter, context->context);
    }
    free(context);
}

int mtp_bridge_read_event_async(mtp_bridge_handle_t *handle, mtp_bridge_event_callback_t callback, void *context) {
    if (callback == NULL || mtp_bridge_lock_connected(handle) != 0) return -1;
    mtp_bridge_event_context_t *event_context = malloc(sizeof(*event_context));
    if (event_context == NULL) {
        mtp_bridge_set_error(handle, "Failed to allocate MTP event context");
        pthread_mutex_unlock(&handle->mutex);
        return -1;
    }
    event_context->callback = callback;
    event_context->context = context;
    LIBMTP_Clear_Errorstack(handle->device);
    int result = LIBMTP_Read_Event_Async(handle->device, mtp_bridge_event_callback, event_context);
    if (result != 0) {
        free(event_context);
        mtp_bridge_set_error_from_errorstack(handle, "Failed to read MTP event asynchronously");
    } else {
        mtp_bridge_set_error(handle, "");
    }
    pthread_mutex_unlock(&handle->mutex);
    return result;
}

int mtp_bridge_handle_events_timeout_completed(long seconds, long microseconds, int *completed) {
    struct timeval timeout = { .tv_sec = seconds, .tv_usec = microseconds };
    return LIBMTP_Handle_Events_Timeout_Completed(&timeout, completed);
}
