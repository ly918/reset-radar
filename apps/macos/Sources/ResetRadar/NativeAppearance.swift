import SwiftUI
import AppKit

/// Warm gold in dark appearance; deeper gold keeps contrast on light glass.
enum RadarPalette {
    static let gold = Color(nsColor: NSColor(name: "RadarGold") { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.90, green: 0.77, blue: 0.48, alpha: 1)
        }
        return NSColor(srgbRed: 0.51, green: 0.35, blue: 0.08, alpha: 1)
    })
}

/// System materials respond to appearance, accessibility and the actual desktop backdrop.
struct NativeSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.nativeWindowMaterial) private var nativeWindowMaterial
    func body(content: Content) -> some View {
        if nativeWindowMaterial {
            if #available(macOS 26.0, *), !reduceTransparency {
                // Attenuate text behind clear glass without fading our own content
                // or adding a second blur. The neutral fill follows system appearance.
                content.background {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.60))
                }
            } else {
                content
            }
        } else if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor))
        } else if #available(macOS 26.0, *) {
            content.background {
                Color.clear.glassEffect(.clear, in: RoundedRectangle(cornerRadius: 20))
            }.containerBackground(.clear, for: .window)
                .background(TransparentWindow())
        } else if #available(macOS 15.0, *) {
            content.containerBackground(.clear, for: .window).background(WindowBackdrop())
        } else {
            content.background(WindowBackdrop())
        }
    }
}
/// Clear both the SwiftUI window container above and the AppKit window itself.
/// A clear NSWindow alone leaves the MenuBarExtra container's default fill in place.
struct TransparentWindow: NSViewRepresentable {
    final class View: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isOpaque = false
            window?.backgroundColor = .clear
            window?.titlebarAppearsTransparent = true
        }
    }
    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ view: View, context: Context) {
        view.window?.isOpaque = false
        view.window?.backgroundColor = .clear
    }
}
struct NativeGlassControls: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            content.buttonStyle(NativeGlassButtonStyle())
        } else {
            content.buttonStyle(.bordered)
        }
    }
}
@available(macOS 26.0, *)
private struct NativeGlassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background {
                Color.clear.glassEffect(.regular.interactive(), in: Capsule())
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
    }
}
struct WindowBackdrop: NSViewRepresentable {
    final class BackdropView: NSVisualEffectView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isOpaque = false
            window?.backgroundColor = .clear
            window?.titlebarAppearsTransparent = true
        }
    }
    func makeNSView(context: Context) -> BackdropView {
        let view = BackdropView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: BackdropView, context: Context) { }
}
struct NativeSectionStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label.font(.headline)
            configuration.content
        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
    }
}
extension View {
    func nativeSurface() -> some View { modifier(NativeSurface()) }
    func nativeGlassControls() -> some View { modifier(NativeGlassControls()) }
}
