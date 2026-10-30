import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)
            
            Text("macMTP")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Version \(AppVersion.current)")
                .font(.body)
                .foregroundColor(.secondary)
            
            Text("A fast, native macOS Android file transfer utility built with Swift and C.")
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
            
            Text("Powered by LibMTP.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 8)
        }
        .frame(width: 320, height: 260)
        .padding()
    }
}
