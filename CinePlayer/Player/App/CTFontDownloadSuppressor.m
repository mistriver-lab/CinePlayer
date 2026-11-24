#import <TargetConditionals.h>
#if TARGET_OS_IOS
#import <CoreFoundation/CoreFoundation.h>
#import <CoreText/CoreText.h>
#import <dispatch/dispatch.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
bool CTFontDescriptorMatchFontDescriptorsWithProgressHandler(
    CFArrayRef descriptors,
    CFSetRef mandatoryAttributes,
    CTFontDescriptorProgressHandler progressBlock
) {
    (void)descriptors;
    (void)mandatoryAttributes;
    if (progressBlock) {
        CTFontDescriptorProgressHandler blockCopy = [progressBlock copy];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            CFDictionaryRef emptyInfo = CFDictionaryCreate(
                kCFAllocatorDefault,
                NULL,
                NULL,
                0,
                &kCFTypeDictionaryKeyCallBacks,
                &kCFTypeDictionaryValueCallBacks
            );
            if (emptyInfo) {
                blockCopy(kCTFontDescriptorMatchingDidFinish, emptyInfo);
                CFRelease(emptyInfo);
            }
        });
    }
    return true;
}
#pragma clang diagnostic pop
#endif
