#import <BuildConfigExtra/BuildConfigExtra.h>

#include <mach-o/dyld.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <libkern/OSByteOrder.h>
#include <limits.h>
#include <string.h>

#import <CommonCrypto/CommonDigest.h>
#import <PKCS/PKCS.h>

static NSData *sha1(NSData *data) {
    uint8_t digest[20];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    
    return [[NSData alloc] initWithBytes:digest length:20];
}

enum {
    EmbeddedSignatureMagic = 0xfade0cc0,
    EntitlementsMagic = 0xfade7171,
    CMSSignatureMagic = 0xfade0b01,
};

static uint32_t readBigEndian32(const uint8_t *bytes) {
    uint32_t value;
    memcpy(&value, bytes, sizeof(value));
    return OSSwapBigToHostInt32(value);
}

static NSData *signatureEntry(const uint8_t *bytes, size_t size, uint32_t entryMagic) {
    const size_t headerSize = 12;
    const size_t indexSize = 8;
    const size_t entryHeaderSize = 8;
    if (size < headerSize || readBigEndian32(bytes) != EmbeddedSignatureMagic) {
        return nil;
    }
    size_t length = readBigEndian32(bytes + 4);
    uint32_t entryCount = readBigEndian32(bytes + 8);
    if (length < headerSize || length > size || entryCount > (length - headerSize) / indexSize) {
        return nil;
    }
    for (uint32_t i = 0; i < entryCount; i++) {
        size_t entryOffset = readBigEndian32(bytes + headerSize + i * indexSize + 4);
        if (entryOffset < headerSize + entryCount * indexSize || entryOffset > length - entryHeaderSize) {
            return nil;
        }
        const uint8_t *entry = bytes + entryOffset;
        if (readBigEndian32(entry) == entryMagic) {
            size_t entryLength = readBigEndian32(entry + 4);
            if (entryLength <= entryHeaderSize || entryLength > length - entryOffset) {
                return nil;
            }
            return [NSData dataWithBytes:entry + entryHeaderSize length:entryLength - entryHeaderSize];
        }
    }
    return nil;
}

static NSData *signatureEntryInMachO(const uint8_t *bytes, size_t size, uint32_t entryMagic) {
    struct mach_header header;
    if (size < sizeof(header)) {
        return nil;
    }
    memcpy(&header, bytes, sizeof(header));
    // The active iOS and macOS slices are little endian.
    size_t offset;
    switch (header.magic) {
        case MH_MAGIC:
            offset = sizeof(struct mach_header);
            break;
        case MH_MAGIC_64:
            offset = sizeof(struct mach_header_64);
            break;
        default:
            return nil;
    }
    if (offset > size || header.sizeofcmds > size - offset) {
        return nil;
    }
    size_t commandsEnd = offset + header.sizeofcmds;
    for (uint32_t i = 0; i < header.ncmds; i++) {
        struct load_command command;
        if (commandsEnd - offset < sizeof(command)) {
            return nil;
        }
        memcpy(&command, bytes + offset, sizeof(command));
        if (command.cmdsize < sizeof(command) || command.cmdsize > commandsEnd - offset) {
            return nil;
        }
        if (command.cmd == LC_CODE_SIGNATURE) {
            struct linkedit_data_command signature;
            if (command.cmdsize < sizeof(signature)) {
                return nil;
            }
            memcpy(&signature, bytes + offset, sizeof(signature));
            if (signature.dataoff > size || signature.datasize > size - signature.dataoff) {
                return nil;
            }
            return signatureEntry(bytes + signature.dataoff, signature.datasize, entryMagic);
        }
        offset += command.cmdsize;
    }
    return nil;
}

static NSData *executableSignatureEntry(uint32_t entryMagic) {
    NSString *path = NSBundle.mainBundle.executablePath;
    NSData *executable = path ? [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL] : nil;
    if (executable.length < sizeof(struct fat_header)) {
        return nil;
    }
    const uint8_t *bytes = executable.bytes;
    if (readBigEndian32(bytes) != FAT_MAGIC) {
        return signatureEntryInMachO(bytes, executable.length, entryMagic);
    }

    const struct mach_header *loaded = _dyld_get_image_header(0);
    uint32_t count = readBigEndian32(bytes + 4);
    size_t offset = sizeof(struct fat_header);
    if (!loaded || count > (executable.length - offset) / sizeof(struct fat_arch)) {
        return nil;
    }
    for (uint32_t i = 0; i < count; i++, offset += sizeof(struct fat_arch)) {
        struct fat_arch arch;
        memcpy(&arch, bytes + offset, sizeof(arch));
        cpu_type_t type = OSSwapBigToHostInt32(arch.cputype);
        cpu_subtype_t subtype = OSSwapBigToHostInt32(arch.cpusubtype);
        if (type != loaded->cputype || (subtype & ~CPU_SUBTYPE_MASK) != (loaded->cpusubtype & ~CPU_SUBTYPE_MASK)) {
            continue;
        }
        size_t sliceOffset = OSSwapBigToHostInt32(arch.offset);
        size_t sliceLength = OSSwapBigToHostInt32(arch.size);
        if (sliceOffset > executable.length || sliceLength > executable.length - sliceOffset) {
            return nil;
        }
        return signatureEntryInMachO(bytes + sliceOffset, sliceLength, entryMagic);
    }
    return nil;
}

@implementation BuildConfigExtra

+ (NSDictionary * _Nonnull)signatureDict {
    NSMutableDictionary *dataDict = [[NSMutableDictionary alloc] init];
    NSData *cms = executableSignatureEntry(CMSSignatureMagic);
    MTPKCS *signature = cms && cms.length <= INT_MAX ? [MTPKCS parse:cms.bytes size:(int)cms.length] : nil;
    if (signature.issuerName != nil) {
        dataDict[@"issuerName"] = signature.issuerName;
    }
    if (signature.subjectName != nil) {
        dataDict[@"name"] = signature.subjectName;
    }
    if (signature.data != nil) {
        dataDict[@"data"] = [sha1(signature.data) base64EncodedStringWithOptions:0];
        dataDict[@"data1"] = [signature.data base64EncodedStringWithOptions:0];
    }
    return dataDict;
}

+ (NSDictionary<NSString *, id> *)applicationEntitlements {
    static NSDictionary<NSString *, id> *entitlements;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSData *entry = executableSignatureEntry(EntitlementsMagic);
        id plist = entry ? [NSPropertyListSerialization propertyListWithData:entry options:NSPropertyListImmutable format:NULL error:NULL] : nil;
        entitlements = [plist isKindOfClass:[NSDictionary class]] ? plist : @{};
    });
    return entitlements;
}

+ (BOOL)hasAPNsEntitlement {
    id environment = [self applicationEntitlements][@"aps-environment"];
    return [environment isEqual:@"development"] || [environment isEqual:@"production"];
}

+ (BOOL)performSystemRegistration:(BOOL (NS_NOESCAPE ^)(void))registration {
    @try {
        return registration();
    } @catch (NSException *exception) {
        NSLog(@"System registration failed: %@", exception.name);
        return NO;
    }
}

@end
