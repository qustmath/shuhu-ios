import SwiftUI
import UIKit

/// 系统相机的 SwiftUI 包装（UIImagePickerController）：拍摄封面照片。
/// 相册侧用 SwiftUI 原生 PhotosPicker（iOS 16+）；两者均为系统组件代取，无需运行时权限
/// （与 Android 票据 07 同一结论：应用不声明 CAMERA 权限，NSCameraUsageDescription 仅作用途说明）。
struct CameraPicker: UIViewControllerRepresentable {
    /// 拍摄完成回调：JPEG 字节 + 文件扩展名。
    var onCapture: (Data, String) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any],
        ) {
            if let image = info[.originalImage] as? UIImage,
               let data = image.jpegData(compressionQuality: 0.9) {
                parent.onCapture(data, "jpg")
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
