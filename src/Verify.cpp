#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wincodec.h>
#include <wrl/client.h>
#include <cstdio>
#include <vector>
using Microsoft::WRL::ComPtr;
int wmain(int argc,wchar_t**argv){
 if(argc<2)return 2;CoInitializeEx(0,COINIT_APARTMENTTHREADED);
 ComPtr<IWICImagingFactory> f;ComPtr<IWICBitmapDecoder>d;ComPtr<IWICBitmapDecoderInfo>di;ComPtr<IWICBitmapFrameDecode>im;ComPtr<IWICFormatConverter>cv;HRESULT hr;
 #define CK(x) hr=(x);printf(#x "=0x%08X\n",(unsigned)hr);if(FAILED(hr))return 1;
 CK(CoCreateInstance(CLSID_WICImagingFactory,0,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&f)));
 if(argc>2){CLSID alt;CLSIDFromString(L"{6215667c-74ca-4076-a769-3f834c3f25f5}",&alt);CK(CoCreateInstance(alt,0,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&d)));ComPtr<IWICStream> stream;CK(f->CreateStream(&stream));CK(stream->InitializeFromFilename(argv[1],GENERIC_READ));CK(d->Initialize(stream.Get(),WICDecodeMetadataCacheOnDemand));}else{CK(f->CreateDecoderFromFilename(argv[1],0,GENERIC_READ,WICDecodeMetadataCacheOnDemand,&d));}
 CK(d->GetDecoderInfo(&di));CLSID cls;CK(di->GetCLSID(&cls));wchar_t id[48];StringFromGUID2(cls,id,48);wprintf(L"selected_codec=%s\n",id);
 wchar_t name[256]={};UINT count=0;di->GetFriendlyName(256,name,&count);wprintf(L"codec_name=%s\n",name);
 CK(d->GetFrame(0,&im));UINT w=0,h=0;CK(im->GetSize(&w,&h));printf("size=%ux%u\n",w,h);if(w>20000||h>20000||((unsigned long long)w*h)>100000000)return 3;
 CK(f->CreateFormatConverter(&cv));CK(cv->Initialize(im.Get(),GUID_WICPixelFormat32bppBGRA,WICBitmapDitherTypeNone,0,0,WICBitmapPaletteTypeCustom));
 std::vector<BYTE> pixels((size_t)w*h*4);CK(cv->CopyPixels(0,w*4,(UINT)pixels.size(),pixels.data()));printf("FULL_IMAGE_OK bytes=%zu\n",pixels.size());return 0;
}
