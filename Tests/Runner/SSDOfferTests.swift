import Foundation

/// Owner, 2026-11-24: on a Mac whose feed served 0.1.81 the page offered the drive's 0.1.75 as the
/// thing to install. The comparison decides which copy the page offers as the update; an older one
/// is still offered, but as a choice that names both versions.
func ssdOfferTests() {
    expect(SSDOffer.driveIsNewer("0.1.75", served: "0.1.81") == false,
           "SO1 a drive older than the feed is not the update")
    expect(SSDOffer.driveIsNewer("1.2", served: "1.0") == true,
           "SO2 a drive newer than the feed is the better copy")
    expect(SSDOffer.driveIsNewer("1.0", served: "1.0") == nil,
           "SO3 an identical copy is nothing to offer")
    expect(SSDOffer.driveIsNewer("1.0", served: nil) == true,
           "SO4 with no feed copy the drive is all there is")
    expect(SSDOffer.driveIsNewer("1.0", served: "") == true,
           "SO4 an empty served version is no copy, not a newer one")
}
