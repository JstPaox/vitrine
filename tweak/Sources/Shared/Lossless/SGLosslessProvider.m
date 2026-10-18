#import "SGLosslessProvider.h"
#import "Core/SGCore.h"
#import "SGLosslessStore.h"

#define kMaxDownloadBytes (1024LL * 1024LL * 1024LL)  // 1 GiB ceiling

static dispatch_queue_t sg_queue;
static NSMutableDictionary<NSString *, NSURLSessionDataTask *> *sg_tasks;

static void ensureInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sg_queue = dispatch_queue_create("spotifyglass.lossless.provider", DISPATCH_QUEUE_SERIAL);
        sg_tasks = [NSMutableDictionary dictionary];
    });
}

static NSString *providerURL(void) {
    return [[NSUserDefaults standardUserDefaults] stringForKey:SGKeyLosslessProviderURL];
}

static NSString *providerToken(void) {
    return [[NSUserDefaults standardUserDefaults] stringForKey:SGKeyLosslessProviderToken];
}

// Encode a query value for the URL.
static NSString *encode(NSString *value) {
    return CFBridgingRelease(CFURLCreateStringByAddingPercentEscapes(NULL,
        (CFStringRef)value, NULL, CFStringConvertNSStringEncodingToEncoding(NSUTF8StringEncoding),
        kCFStringEncodingUTF8));
}

// Track: try the manifest's streamURL first, else /stream/{id}.
static void streamURLForTrack(NSDictionary *track, NSString *quality,
    void (^)(NSString *_Nullable url, NSString *_Nullable error)) done) {
    NSString *url = track[@"streamURL"];
    if (url && url.length) { done(url, nil); return; }
    NSString *id = track[@"id"] ?: track[@"trackId"];
    if (!id || !id.length) { done(nil, @"no stream id"); return; }
    NSString *base = providerURL();
    if (!base || !base.length) { done(nil, @"no provider URL"); return; }
    NSString *request = [NSString stringWithFormat:@"%@/stream/%@?quality=%@", base, encode(id), encode(quality)];
    NSURL *requestURL = [NSURL URLWithString:request];
    if (!requestURL) { done(nil, @"bad stream URL"); return; }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:requestURL];
    req.HTTPMethod = @"GET";
    if (providerToken().length)
        req.allHTTPHeaderFields = @{@"Authorization": [NSString stringWithFormat:@"Bearer %@", providerToken()]};
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
            if (error) { done(nil, error.localizedDescription); return; }
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
            if (http.statusCode == 404) { done(nil, @"not found"); return; }
            if (http.statusCode < 200 || http.statusCode >= 300) {
                done(nil, [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode]); return;
            }
            if (!data || data.length == 0) { done(nil, @"empty stream answer"); return; }
            NSError *jsonError;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if (!json) { done(nil, jsonError.localizedDescription); return; }
            NSString *stream = json[@"url"] ?: json[@"streamURL"] ?: json[@"downloadURL"];
            if (!stream || !stream.length) { done(nil, @"no stream url"); return; }
            done(stream, nil);
        }];
    [task resume];
}

// Download `url` into Documents/Lossless, remember it by URI, then report the path.
static void downloadToCache(NSString *urlString, NSString *uri, NSString *title, double duration,
    void (^)(NSString *_Nullable path, NSString *_Nullable error)) done) {
    NSURL *downloadURL = [NSURL URLWithString:urlString];
    if (!downloadURL) { done(nil, @"bad download URL"); return; }
    NSString *ext = downloadURL.pathExtension;
    if (![ext isEqualToString:@"flac"] && ![ext isEqualToString:@"m4a"] && ![ext isEqualToString:@"caf"])
        ext = @"flac";
    NSString *directory = SGLosslessStoreDirectory();
    NSString *name = [NSString stringWithFormat:@"%@.%@", [uri lastPathComponent], ext];
    NSString *path = [directory stringByAppendingPathComponent:name];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        SGLosslessStoreRemember(uri, path);
        done(path, nil);
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:downloadURL];
    if (providerToken().length)
        req.allHTTPHeaderFields = @{@"Authorization": [NSString stringWithFormat:@"Bearer %@", providerToken()]};
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{ [sg_tasks removeObjectForKey:uri]; });
            if (error) { done(nil, error.localizedDescription); return; }
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
            if (http.statusCode < 200 || http.statusCode >= 300) {
                done(nil, [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode]); return;
            }
            if (!data || data.length == 0) { done(nil, @"empty download"); return; }
            if (data.length > kMaxDownloadBytes) { done(nil, @"file too large"); return; }
            NSError *writeError;
            if (![data writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
                done(nil, writeError.localizedDescription); return;
            }
            SGLosslessStoreRemember(uri, path);
            done(path, nil);
        }];
    [sg_tasks setObject:task forKey:uri];
    [task resume];
}

BOOL SGLosslessProviderDownloadForTrack(NSString *uri, NSString *title, double duration,
    void (^_Nullable)(NSString *_Nullable path, NSString *_Nullable error)) callback) {
    if (!callback) return NO;
    ensureInit();
    NSString *base = providerURL();
    if (!base || !base.length) { callback(nil, @"no provider URL configured"); return NO; }
    NSURLSessionDataTask *existing = sg_tasks[uri];
    if (existing) {
        [existing cancel];
        [sg_tasks removeObjectForKey:uri];
    }
    NSString *q = encode(title ?: @"");
    NSString *request = [NSString stringWithFormat:@"%@/search?q=%@&quality=lossless", base, q];
    NSURL *requestURL = [NSURL URLWithString:request];
    if (!requestURL) { callback(nil, @"bad search URL"); return NO; }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:requestURL];
    req.HTTPMethod = @"GET";
    if (providerToken().length)
        req.allHTTPHeaderFields = @{@"Authorization": [NSString stringWithFormat:@"Bearer %@", providerToken()]};
    __block BOOL completed = NO;
    NSURLSessionDataTask *searchTask = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{ [sg_tasks removeObjectForKey:uri]; });
            if (completed) return;
            completed = YES;
            if (error) { callback(nil, error.localizedDescription); return; }
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
            if (http.statusCode < 200 || http.statusCode >= 300) {
                callback(nil, [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode]); return;
            }
            if (!data || data.length == 0) { callback(nil, @"empty search"); return; }
            NSError *jsonError;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if (!json) { callback(nil, jsonError.localizedDescription); return; }
            NSArray *tracks = json[@"tracks"];
            if (![tracks isKindOfClass:NSArray.class] || tracks.count == 0) { callback(nil, @"no tracks"); return; }
            NSDictionary *pick = tracks.firstObject;
            for (NSDictionary *candidate in tracks) {
                NSString *ct = candidate[@"title"];
                if (ct && title && [ct localizedCaseInsensitiveContainsString:title]) { pick = candidate; break; }
            }
            streamURLForTrack(pick, @"lossless", ^(NSString *_Nullable streamURL, NSString *_Nullable err) {
                if (!streamURL) { callback(nil, err ?: @"no stream"); return; }
                downloadToCache(streamURL, uri, title, duration, callback);
            });
        }];
    [sg_tasks setObject:searchTask forKey:uri];
    [searchTask resume];
    return YES;
}

BOOL SGLosslessProviderIsDownloading(NSString *uri) {
    ensureInit();
    return sg_tasks[uri] != nil;
}

void SGLosslessProviderCancel(NSString *uri) {
    ensureInit();
    NSURLSessionDataTask *task = sg_tasks[uri];
    if (task) [task cancel];
    [sg_tasks removeObjectForKey:uri];
}
