import Foundation

func downloadProgressTests() {
    DownloadControl.updateProgress("preparing")
    expect(DownloadControl.progress.phase == "preparing" && DownloadControl.progress.received == nil,
           "DP1 a queued install never claims download or install progress")
    DownloadControl.updateProgress("downloading", received: 0, total: 4096)
    expect(DownloadControl.progress.received == 0 && DownloadControl.progress.total == 4096,
           "DP2 download shows zero bytes before its first delivery")
    DownloadControl.updateProgress("downloading", received: 1024, total: 4096)
    expect(DownloadControl.progress.received == 1024 && DownloadControl.progress.total == 4096,
           "DP2 download bytes follow actual deliveries")
    DownloadControl.updateProgress("downloading", received: 1024)
    expect(DownloadControl.progress.total == nil, "DP3 an unknown download total stays unknown")
    DownloadControl.updateProgress("checking")
    expect(DownloadControl.progress.phase == "checking" && DownloadControl.progress.received == nil,
           "DP4 checking the completed download is distinct from downloading")
    DownloadControl.updateProgress("installing")
    expect(DownloadControl.progress.phase == "installing", "DP4 only the recipe phase says installing")
    DownloadControl.updateProgress("preparing")
    expect(DownloadControl.progress.received == nil && DownloadControl.progress.total == nil,
           "DP5 a new request cannot inherit old transfer counters")
}
