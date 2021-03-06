//
// shoes/http/nsurl.m
// the downloader routines using nsurl classes.
//
#include "shoes/app.h"
#include "shoes/ruby.h"
#include "shoes/internal.h"
#include "shoes/config.h"
#include "shoes/http.h"
#include "shoes/version.h"
#include "shoes/world.h"
#include "shoes/native.h"

#import <Cocoa/Cocoa.h>

@interface ShoesHttp : NSObject
{
  char *dest;
  unsigned long destlen;
  NSURLConnection *conn;
  NSURLDownload *down;
  NSURLResponse *resp;
  NSFileManager *fm;
  long long size;
  long long total;
  shoes_download_handler handler;
  SHOES_TIME last;
  NSMutableData *bytes;
  void *data;
}
@end

@implementation ShoesHttp
- (id)init
{
  if ((self = [super init]))
  {
    bytes = [[NSMutableData data] retain];
    fm = [NSFileManager defaultManager];
    destlen = 0;
  }
  return self;
}
- (void)download: (shoes_download_request *)req
{
  char slash[2] = "/";
  if (req->path[0] == '/') slash[0] = '\0';
  NSString *url = [NSString stringWithFormat: @"http://%s:%d%s%s", req->host, req->port, slash, req->path];
  NSString *uagent = [NSString stringWithFormat: @"Shoes/0.r%d (%s) %s/%d", 
    SHOES_REVISION, SHOES_PLATFORM, SHOES_RELEASE_NAME, SHOES_BUILD_DATE];
  NSMutableURLRequest *nsreq = [NSMutableURLRequest requestWithURL: 
    [NSURL URLWithString: url]
    cachePolicy: NSURLRequestUseProtocolCachePolicy
    timeoutInterval: 60.0];
  [nsreq setValue: uagent forHTTPHeaderField: @"User-Agent"];

  handler = req->handler;
  data = req->data;
  last.tv_sec = 0;
  last.tv_usec = 0;
  size = total = 0;
  if (req->mem != NULL)
  {
    dest = req->mem;
    destlen = req->memlen;
    conn = [[NSURLConnection alloc] initWithRequest: nsreq
      delegate: self];
  }
  else
  {
    dest = req->filepath;
    down = [[NSURLDownload alloc] initWithRequest: nsreq delegate: self];
  }
}
- (void)readHeaders: (NSURLResponse *)response
{
  if ([response respondsToSelector:@selector(allHeaderFields)])
  {
    NSHTTPURLResponse* httpresp = (NSHTTPURLResponse *)response;
    if ([httpresp statusCode])
    {
      shoes_download_event event;
      event.stage = SHOES_HTTP_STATUS;
      event.status = [httpresp statusCode];
      if (handler != NULL) handler(&event, data);
    }

    NSDictionary *hdrs = [httpresp allHeaderFields];
    if (hdrs)
    {
      NSString *key;
      NSEnumerator *keys = [hdrs keyEnumerator];
      while (key = [keys nextObject])
      {
        NSString *val = [hdrs objectForKey: key];
        shoes_download_event event;
        event.stage = SHOES_HTTP_HEADER;
        event.hkey = [key UTF8String];
        event.hkeylen = strlen(event.hkey);
        event.hval = [val UTF8String];
        event.hvallen = strlen(event.hval);
        if (handler != NULL) handler(&event, data);
      }
    }
  }
}
- (void)connection: (NSURLConnection *)c didReceiveResponse: (NSURLResponse *)response
{
  [self readHeaders: response];
  size = total = 0;
  if ([response expectedContentLength] != NSURLResponseUnknownLength)
    total = [response expectedContentLength];
  HTTP_EVENT(handler, SHOES_HTTP_CONNECTED, last, 0, 0, total, data, NULL, [c cancel]);
  [bytes setLength: 0];
}
- (void)connection: (NSURLConnection *)c didReceiveData: (NSData *)chunk
{
  [bytes appendData: chunk];
  size += [chunk length];
  HTTP_EVENT(handler, SHOES_HTTP_TRANSFER, last, size * 100.0 / total, size,
             total, data, NULL, [c cancel]);
}
- (void)connectionDidFinishLoading: (NSURLConnection *)c
{
  total = [bytes length];
  if ([bytes length] > destlen)
    SHOE_REALLOC_N(dest, char, [bytes length]);
  [bytes getBytes: dest];
  HTTP_EVENT(handler, SHOES_HTTP_COMPLETED, last, 100, total, total, data, [bytes mutableBytes], 1);
  [c release];
}
- (void)download: (NSURLDownload *)download decideDestinationWithSuggestedFilename: (NSString *)filename
{
  NSString *path = [NSString stringWithUTF8String: dest];
  [download setDestination: path allowOverwrite: YES];
}
- (void)setDownloadResponse: (NSURLResponse *)aDownloadResponse
{
  [aDownloadResponse retain];
  [resp release];
  resp = aDownloadResponse;
}
- (void)download: (NSURLDownload *)download didReceiveResponse: (NSURLResponse *)response
{
  [self readHeaders: response];
  size = total = 0;
  if ([response expectedContentLength] != NSURLResponseUnknownLength)
    total = [response expectedContentLength];
  HTTP_EVENT(handler, SHOES_HTTP_CONNECTED, last, 0, 0, total, data, NULL, [download cancel]);
  [self setDownloadResponse: response];
}
- (void)download: (NSURLDownload *)download didReceiveDataOfLength: (unsigned)length
{
  size += length;
  HTTP_EVENT(handler, SHOES_HTTP_TRANSFER, last, size * 100.0 / total, size,
             total, data, NULL, [download cancel]);
}
- (void)downloadDidFinish: (NSURLDownload *)download
{
  HTTP_EVENT(handler, SHOES_HTTP_COMPLETED, last, 100, total, total, data, NULL, 1);
  [download release];
}
@end

void
shoes_download(shoes_download_request *req)
{
  ShoesHttp *http = [[ShoesHttp alloc] init];
  [http download: req];
}

void
shoes_queue_download(shoes_download_request *req)
{
  ShoesHttp *http = [[ShoesHttp alloc] init];
  [http download: req];
}

VALUE
shoes_http_error(SHOES_DOWNLOAD_ERROR code)
{
  char *errorString = [[code localizedDescription] UTF8String];
  return rb_str_new2(errorString);
}

SHOES_DOWNLOAD_HEADERS
shoes_http_headers(VALUE hsh)
{
  return NULL;
}
