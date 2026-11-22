#include <libplatform/libplatform.h>
#include <v8.h>

int main() {
    auto platform = v8::platform::NewDefaultPlatform();
    v8::V8::InitializePlatform(platform.get());
    v8::V8::Initialize();
    auto allocator = std::unique_ptr<v8::ArrayBuffer::Allocator>(
        v8::ArrayBuffer::Allocator::NewDefaultAllocator());
    v8::Isolate::CreateParams params;
    params.array_buffer_allocator = allocator.get();
    auto isolate = v8::Isolate::New(params);
    bool ok = false;
    {
        v8::Isolate::Scope isolate_scope(isolate);
        v8::HandleScope handles(isolate);
        auto context = v8::Context::New(isolate);
        v8::Context::Scope context_scope(context);
        auto source = v8::String::NewFromUtf8Literal(isolate, R"(
            new Intl.NumberFormat('de-DE').format(1234.5) === '1.234,5' &&
            new Intl.DateTimeFormat('en-US', {year:'numeric', timeZone:'UTC'}).format(0) === '1970' &&
            new WebAssembly.Instance(new WebAssembly.Module(new Uint8Array([
              0,97,115,109,1,0,0,0, 1,5,1,96,0,1,127, 3,2,1,0,
              7,7,1,3,114,117,110,0,0, 10,6,1,4,0,65,42,11
            ]))).exports.run() === 42
        )");
        v8::Local<v8::Script> script;
        v8::Local<v8::Value> result;
        ok = v8::Script::Compile(context, source).ToLocal(&script) &&
             script->Run(context).ToLocal(&result) && result->IsTrue();
    }
    isolate->Dispose();
    v8::V8::Dispose();
    v8::V8::DisposePlatform();
    return ok ? 0 : 1;
}
