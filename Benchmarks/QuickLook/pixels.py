from pathlib import Path
import ctypes as C

def colors(path):
    cf = C.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    io = C.CDLL('/System/Library/Frameworks/ImageIO.framework/ImageIO')
    cg = C.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
    cf.CFURLCreateFromFileSystemRepresentation.argtypes = [C.c_void_p, C.c_char_p, C.c_long, C.c_bool]
    cf.CFURLCreateFromFileSystemRepresentation.restype = C.c_void_p
    cf.CFRelease.argtypes = [C.c_void_p]
    io.CGImageSourceCreateWithURL.argtypes = [C.c_void_p, C.c_void_p]
    io.CGImageSourceCreateWithURL.restype = C.c_void_p
    io.CGImageSourceCreateImageAtIndex.argtypes = [C.c_void_p, C.c_size_t, C.c_void_p]
    io.CGImageSourceCreateImageAtIndex.restype = C.c_void_p
    for name in ['CGImageGetWidth', 'CGImageGetHeight']:
        getattr(cg, name).argtypes = [C.c_void_p]
        getattr(cg, name).restype = C.c_size_t
    cg.CGColorSpaceCreateDeviceRGB.restype = C.c_void_p
    cg.CGBitmapContextCreate.argtypes = [C.c_void_p, C.c_size_t, C.c_size_t, C.c_size_t, C.c_size_t, C.c_void_p, C.c_uint32]
    cg.CGBitmapContextCreate.restype = C.c_void_p
    class Point(C.Structure):
        _fields_ = [('x', C.c_double), ('y', C.c_double)]
    class Size(C.Structure):
        _fields_ = [('width', C.c_double), ('height', C.c_double)]
    class Rect(C.Structure):
        _fields_ = [('origin', Point), ('size', Size)]
    cg.CGContextDrawImage.argtypes = [C.c_void_p, Rect, C.c_void_p]
    cg.CGContextRelease.argtypes = [C.c_void_p]
    cg.CGImageRelease.argtypes = [C.c_void_p]
    cg.CGColorSpaceRelease.argtypes = [C.c_void_p]
    encoded = bytes(Path(path).resolve())
    url = cf.CFURLCreateFromFileSystemRepresentation(None, encoded, len(encoded), False)
    source = io.CGImageSourceCreateWithURL(url, None)
    assert source, 'Cannot decode image'
    image = io.CGImageSourceCreateImageAtIndex(source, 0, None)
    assert image
    width, height = cg.CGImageGetWidth(image), cg.CGImageGetHeight(image)
    assert 0 < width * height < 20_000_000
    data = (C.c_ubyte * (width * height * 4))()
    space = cg.CGColorSpaceCreateDeviceRGB()
    context = cg.CGBitmapContextCreate(data, width, height, 8, width * 4, space, 0x4001)
    assert context
    cg.CGContextDrawImage(context, Rect(Point(0, 0), Size(width, height)), image)
    result = {'width': width, 'height': height, 'red': 0, 'green': 0, 'blue': 0}
    raw = bytes(data)
    for index in range(0, len(raw), 4):
        red, green, blue, alpha = raw[index:index + 4]
        if alpha < 200:
            continue
        result['red'] += red > 180 and green < 85 and blue < 85
        result['green'] += green > 150 and red < 85 and blue < 85
        result['blue'] += blue > 160 and red < 85 and green < 85
    cg.CGContextRelease(context)
    cg.CGColorSpaceRelease(space)
    cg.CGImageRelease(image)
    cf.CFRelease(source)
    cf.CFRelease(url)
    return result

if __name__ == '__main__':
    import json, sys
    print(json.dumps(colors(sys.argv[1])))
