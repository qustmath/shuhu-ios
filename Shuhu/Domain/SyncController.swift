import Foundation
import Combine

/// 新账号的云端数据概览（换账号弹窗提示用）。
public struct SyncCloudSummary: Equatable, Sendable {
    public let liveBooks: Int64
    public let liveRecords: Int64

    public init(liveBooks: Int64, liveRecords: Int64) {
        self.liveBooks = liveBooks
        self.liveRecords = liveRecords
    }
}

/// 同步的 UI 观察接缝（data-sync 票 08）：设置页「立即同步」与「上次同步」只依赖本接口。
/// 由 SyncEngine 实现。与 Android `SyncController` 对应（StateFlow → CurrentValueSubject）。
public protocol SyncController: AnyObject {
    /// 当前是否有一轮同步在进行（立即同步按钮的进行中态）。
    var syncing: CurrentValueSubject<Bool, Never> { get }

    /// 上次成功同步的 epoch 毫秒；0 = 从未同步。
    var lastSyncAt: CurrentValueSubject<Int64, Never> { get }

    /// 待裁决的账号切换：非 nil = 弹窗等待用户选择，期间自动/手动同步均被挂起。
    var pendingSwitchAccount: CurrentValueSubject<AuthMember?, Never> { get }

    /// 待裁决新账号的云端概览；nil = 尚未取到（获取中或失败，均按「未知」展示）。
    var pendingSwitchCloudSummary: CurrentValueSubject<SyncCloudSummary?, Never> { get }

    /// 手动触发一轮完整同步。false = 未登录、换账号待裁决，或网络/服务端失败。
    func syncNow() async -> Bool

    /// 裁决换账号弹窗：merge=true 并入新账号（LWW 静默合并）；false 清空本地后按云端全量重建。
    func resolveAccountSwitch(mergeIntoNewAccount: Bool) async
}
