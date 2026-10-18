#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Lossless source configuration keys (read from NSUserDefaults).
#define SGKeyLosslessProviderURL   @"spotifyglass.lossless.providerURL"
#define SGKeyLosslessProviderToken @"spotifyglass.lossless.providerToken"

// Searches the configured lossless source for the track, downloads the first lossless match into
// Documents/Lossless and reports the local path on the main thread. `duration` may be -1 when
// unknown. Returns YES while a request is in flight; a later call for the same URI replaces it.
BOOL SGLosslessProviderDownloadForTrack(NSString *uri, NSString *title, double duration,
    void (^ _Nullable)(NSString *_Nullable path, NSString *_Nullable error)) callback;

// Whether a download for `uri` is in flight.
BOOL SGLosslessProviderIsDownloading(NSString *uri);

// Cancel any in-flight download for `uri`.
void SGLosslessProviderCancel(NSString *uri);

NS_ASSUME_NONNULL_END
