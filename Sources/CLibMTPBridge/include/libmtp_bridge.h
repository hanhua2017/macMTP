#ifndef MACMTP_LIBMTP_BRIDGE_H
#define MACMTP_LIBMTP_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mtp_bridge_handle mtp_bridge_handle_t;
typedef void (*mtp_bridge_progress_callback_t)(
    const char *full_path,
    const char *name,
    uint64_t sent,
    uint64_t total,
    void *context);
typedef void (*mtp_bridge_data_callback_t)(
    const unsigned char *data,
    uint32_t length,
    void *context);
typedef int (*mtp_bridge_data_request_callback_t)(
    unsigned char *buffer,
    uint32_t requested,
    uint32_t *provided,
    void *context);
typedef void (*mtp_bridge_event_callback_t)(
    int result,
    int event,
    uint32_t parameter,
    void *context);

void mtp_bridge_set_debug(int level);
mtp_bridge_handle_t *mtp_bridge_create(void);
void mtp_bridge_destroy(mtp_bridge_handle_t *handle);
const char *mtp_bridge_last_error(mtp_bridge_handle_t *handle);
void mtp_bridge_free_string(char *value);
void mtp_bridge_free_data(void *value);
char *mtp_bridge_supported_devices_json(void);
char *mtp_bridge_raw_devices_json(void);
int mtp_bridge_check_specific_device(int busno, int devno);
int mtp_bridge_connect(mtp_bridge_handle_t *handle);
void mtp_bridge_disconnect(mtp_bridge_handle_t *handle);
int mtp_bridge_reset_device(mtp_bridge_handle_t *handle);
char *mtp_bridge_device_info_json(mtp_bridge_handle_t *handle);
char *mtp_bridge_device_extended_info_json(mtp_bridge_handle_t *handle);
int mtp_bridge_set_friendly_name(mtp_bridge_handle_t *handle, const char *name);
int mtp_bridge_set_sync_partner(mtp_bridge_handle_t *handle, const char *partner);
int mtp_bridge_get_battery_level(mtp_bridge_handle_t *handle, uint8_t *maximum, uint8_t *current);
char *mtp_bridge_secure_time(mtp_bridge_handle_t *handle);
char *mtp_bridge_device_certificate(mtp_bridge_handle_t *handle);
char *mtp_bridge_supported_filetypes_json(mtp_bridge_handle_t *handle);
char *mtp_bridge_capabilities_json(mtp_bridge_handle_t *handle);
char *mtp_bridge_storages_json(mtp_bridge_handle_t *handle);
int mtp_bridge_refresh_storage(mtp_bridge_handle_t *handle, int sort_mode);
int mtp_bridge_format_storage(mtp_bridge_handle_t *handle, uint32_t storage_id);
char *mtp_bridge_list_directory_json(mtp_bridge_handle_t *handle, uint32_t storage_id, const char *path, int recursive);
char *mtp_bridge_filelisting_json(mtp_bridge_handle_t *handle);
char *mtp_bridge_children_json(mtp_bridge_handle_t *handle, uint32_t storage_id, uint32_t parent_id);
char *mtp_bridge_file_metadata_json(mtp_bridge_handle_t *handle, uint32_t object_id);
int mtp_bridge_create_folder(mtp_bridge_handle_t *handle, uint32_t storage_id, const char *path);
int mtp_bridge_delete_path(mtp_bridge_handle_t *handle, uint32_t storage_id, const char *path);
int mtp_bridge_rename_path(
    mtp_bridge_handle_t *handle,
    uint32_t storage_id,
    const char *path,
    const char *new_name);
int mtp_bridge_move_path(
    mtp_bridge_handle_t *handle,
    uint32_t storage_id,
    const char *source_path,
    const char *destination_parent_path);
char *mtp_bridge_file_exists_json(
    mtp_bridge_handle_t *handle,
    uint32_t storage_id,
    const char **paths,
    int count);
int mtp_bridge_resolve_object_id(
    mtp_bridge_handle_t *handle,
    uint32_t storage_id,
    const char *path,
    uint32_t *object_id,
    int *is_folder);
int mtp_bridge_delete_object(mtp_bridge_handle_t *handle, uint32_t object_id);
int mtp_bridge_move_object(mtp_bridge_handle_t *handle, uint32_t object_id, uint32_t storage_id, uint32_t parent_id);
int mtp_bridge_copy_object(mtp_bridge_handle_t *handle, uint32_t object_id, uint32_t storage_id, uint32_t parent_id);
int mtp_bridge_set_object_filename(mtp_bridge_handle_t *handle, uint32_t object_id, const char *name);
char *mtp_bridge_get_object_string(mtp_bridge_handle_t *handle, uint32_t object_id, int property);
uint64_t mtp_bridge_get_object_u64(mtp_bridge_handle_t *handle, uint32_t object_id, int property, uint64_t fallback);
uint32_t mtp_bridge_get_object_u32(mtp_bridge_handle_t *handle, uint32_t object_id, int property, uint32_t fallback);
uint16_t mtp_bridge_get_object_u16(mtp_bridge_handle_t *handle, uint32_t object_id, int property, uint16_t fallback);
uint8_t mtp_bridge_get_object_u8(mtp_bridge_handle_t *handle, uint32_t object_id, int property, uint8_t fallback);
int mtp_bridge_set_object_string(mtp_bridge_handle_t *handle, uint32_t object_id, int property, const char *value);
int mtp_bridge_set_object_u32(mtp_bridge_handle_t *handle, uint32_t object_id, int property, uint32_t value);
int mtp_bridge_set_object_u16(mtp_bridge_handle_t *handle, uint32_t object_id, int property, uint16_t value);
int mtp_bridge_set_object_u8(mtp_bridge_handle_t *handle, uint32_t object_id, int property, uint8_t value);
const char *mtp_bridge_property_description(int property);
const char *mtp_bridge_filetype_description(int filetype);
int mtp_bridge_is_property_supported(mtp_bridge_handle_t *handle, int property, int filetype);
char *mtp_bridge_allowed_property_values_json(mtp_bridge_handle_t *handle, int property, int filetype);
int mtp_bridge_get_thumbnail(mtp_bridge_handle_t *handle, uint32_t object_id, unsigned char **data, uint32_t *size);
char *mtp_bridge_representative_sample_format_json(mtp_bridge_handle_t *handle, int filetype);
int mtp_bridge_get_representative_sample(mtp_bridge_handle_t *handle, uint32_t object_id, unsigned char **data, uint64_t *size);
int mtp_bridge_send_representative_sample(mtp_bridge_handle_t *handle, uint32_t object_id, const unsigned char *data, uint64_t size, uint32_t width, uint32_t height, uint32_t duration, int filetype);
int mtp_bridge_get_partial_object(mtp_bridge_handle_t *handle, uint32_t object_id, uint64_t offset, uint32_t max_bytes, unsigned char **data, uint32_t *size);
int mtp_bridge_send_partial_object(mtp_bridge_handle_t *handle, uint32_t object_id, uint64_t offset, const unsigned char *data, uint32_t size);
int mtp_bridge_begin_edit_object(mtp_bridge_handle_t *handle, uint32_t object_id);
int mtp_bridge_end_edit_object(mtp_bridge_handle_t *handle, uint32_t object_id);
int mtp_bridge_truncate_object(mtp_bridge_handle_t *handle, uint32_t object_id, uint64_t size);
int mtp_bridge_download_file(
    mtp_bridge_handle_t *handle,
    uint32_t storage_id,
    const char *source_path,
    const char *destination_path,
    mtp_bridge_progress_callback_t callback,
    void *context);
int mtp_bridge_download_file_by_id(mtp_bridge_handle_t *handle, uint32_t object_id, const char *destination_path, mtp_bridge_progress_callback_t callback, void *context);
int mtp_bridge_download_file_to_descriptor(mtp_bridge_handle_t *handle, uint32_t object_id, int fd, mtp_bridge_progress_callback_t callback, void *context);
int mtp_bridge_download_file_to_handler(mtp_bridge_handle_t *handle, uint32_t object_id, mtp_bridge_data_callback_t data_callback, void *data_context, mtp_bridge_progress_callback_t progress_callback, void *progress_context);
int mtp_bridge_upload_file(
    mtp_bridge_handle_t *handle,
    uint32_t storage_id,
    const char *source_path,
    const char *destination_dir,
    mtp_bridge_progress_callback_t callback,
    void *context);
int mtp_bridge_upload_file_to_parent(mtp_bridge_handle_t *handle, uint32_t storage_id, uint32_t parent_id, const char *source_path, const char *name, int filetype, mtp_bridge_progress_callback_t callback, void *context);
int mtp_bridge_upload_file_from_descriptor(mtp_bridge_handle_t *handle, uint32_t storage_id, uint32_t parent_id, int fd, const char *name, uint64_t filesize, int filetype, mtp_bridge_progress_callback_t callback, void *context);
int mtp_bridge_upload_file_from_handler(mtp_bridge_handle_t *handle, uint32_t storage_id, uint32_t parent_id, const char *name, uint64_t filesize, int filetype, mtp_bridge_data_request_callback_t data_callback, void *data_context, mtp_bridge_progress_callback_t progress_callback, void *progress_context);
char *mtp_bridge_tracklisting_json(mtp_bridge_handle_t *handle);
char *mtp_bridge_tracklisting_for_storage_json(mtp_bridge_handle_t *handle, uint32_t storage_id);
char *mtp_bridge_track_metadata_json(mtp_bridge_handle_t *handle, uint32_t track_id);
int mtp_bridge_track_exists(mtp_bridge_handle_t *handle, uint32_t track_id);
int mtp_bridge_set_track_name(mtp_bridge_handle_t *handle, uint32_t track_id, const char *name);
int mtp_bridge_update_track_metadata(mtp_bridge_handle_t *handle, uint32_t track_id, const char *title, const char *artist, const char *album, const char *genre, uint16_t track_number, uint16_t rating);
int mtp_bridge_download_track_by_id(mtp_bridge_handle_t *handle, uint32_t track_id, const char *destination_path, mtp_bridge_progress_callback_t callback, void *context);
int mtp_bridge_download_track_to_descriptor(mtp_bridge_handle_t *handle, uint32_t track_id, int fd, mtp_bridge_progress_callback_t callback, void *context);
int mtp_bridge_upload_track_from_file(mtp_bridge_handle_t *handle, uint32_t storage_id, uint32_t parent_id, const char *source_path, const char *filename, const char *title, const char *artist, const char *album, const char *genre, int filetype, mtp_bridge_progress_callback_t callback, void *context);
int mtp_bridge_upload_track_from_descriptor(mtp_bridge_handle_t *handle, uint32_t storage_id, uint32_t parent_id, int fd, const char *filename, const char *title, const char *artist, const char *album, const char *genre, uint64_t filesize, int filetype, mtp_bridge_progress_callback_t callback, void *context);
int mtp_bridge_upload_track_from_handler(mtp_bridge_handle_t *handle, uint32_t storage_id, uint32_t parent_id, const char *filename, const char *title, const char *artist, const char *album, const char *genre, uint64_t filesize, int filetype, mtp_bridge_data_request_callback_t data_callback, void *data_context, mtp_bridge_progress_callback_t progress_callback, void *progress_context);
char *mtp_bridge_folder_list_json(mtp_bridge_handle_t *handle);
char *mtp_bridge_folder_list_for_storage_json(mtp_bridge_handle_t *handle, uint32_t storage_id);
int mtp_bridge_set_folder_name(mtp_bridge_handle_t *handle, uint32_t folder_id, const char *name);
char *mtp_bridge_playlist_list_json(mtp_bridge_handle_t *handle);
char *mtp_bridge_playlist_json(mtp_bridge_handle_t *handle, uint32_t playlist_id);
int mtp_bridge_create_playlist(mtp_bridge_handle_t *handle, uint32_t storage_id, uint32_t parent_id, const char *name, const uint32_t *tracks, uint32_t track_count);
int mtp_bridge_update_playlist(mtp_bridge_handle_t *handle, uint32_t playlist_id, const char *name, const uint32_t *tracks, uint32_t track_count);
int mtp_bridge_set_playlist_name(mtp_bridge_handle_t *handle, uint32_t playlist_id, const char *name);
char *mtp_bridge_album_list_json(mtp_bridge_handle_t *handle);
char *mtp_bridge_album_list_for_storage_json(mtp_bridge_handle_t *handle, uint32_t storage_id);
char *mtp_bridge_album_json(mtp_bridge_handle_t *handle, uint32_t album_id);
int mtp_bridge_create_album(mtp_bridge_handle_t *handle, uint32_t storage_id, uint32_t parent_id, const char *name, const char *artist, const char *composer, const char *genre, const uint32_t *tracks, uint32_t track_count);
int mtp_bridge_update_album(mtp_bridge_handle_t *handle, uint32_t album_id, const char *name, const char *artist, const char *composer, const char *genre, const uint32_t *tracks, uint32_t track_count);
int mtp_bridge_set_album_name(mtp_bridge_handle_t *handle, uint32_t album_id, const char *name);
int mtp_bridge_read_event(mtp_bridge_handle_t *handle, int *event, uint32_t *parameter);
int mtp_bridge_read_event_async(mtp_bridge_handle_t *handle, mtp_bridge_event_callback_t callback, void *context);
int mtp_bridge_handle_events_timeout_completed(long seconds, long microseconds, int *completed);

/*
 * LIBMTP_Custom_Operation is a varargs API. It is intentionally not exposed as
 * a generic Swift-facing ABI; add typed wrappers for specific vendor operations
 * when they are needed.
 */

#ifdef __cplusplus
}
#endif

#endif
