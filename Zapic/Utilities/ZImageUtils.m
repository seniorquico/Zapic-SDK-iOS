#import "ZImageUtils.h"

@implementation ZImageUtils

+ (UIImage *)decodeBase64ToImage:(NSString *)strEncodeData {
    if (!strEncodeData.length) {
        return nil;
    }
    NSData *data = [[NSData alloc] initWithBase64EncodedString:strEncodeData options:NSDataBase64DecodingIgnoreUnknownCharacters];
    return [UIImage imageWithData:data];
}

+ (UIImage *)getZapicLogo {
    NSString *img64 = @"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";

    UIImage *logo = [ZImageUtils decodeBase64ToImage:img64];

    return logo;
}

@end
