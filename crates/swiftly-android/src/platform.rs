//! What the Rust core asks of the Kotlin `Bridge` over JNI: the HTTP stack (`HttpURLConnection`: system trust, user
//! CAs, proxies) and the secret store (Android Keystore AES-GCM). Both are blocking and may be called from any thread;
//! each call attaches the thread to the VM.
#![allow(unsafe_code)]

use std::sync::Arc;

use crate::http_wire::parse_answer;
use jni::objects::{GlobalRef, JByteArray, JClass, JObject, JString, JValue};
use jni::{JNIEnv, JavaVM};
use swiftly_accounts::SecretStore;
use swiftly_desktop::net::{HostHttp, set_host_http};
use swiftly_desktop::store::set_secret_backend;
use swiftly_net::{ErrorKind, HttpRequest, HttpResponse, Method};

struct Kotlin {
    vm: JavaVM,
    bridge: GlobalRef,
}

impl Kotlin {
    fn http(&self, request: &HttpRequest) -> Result<Vec<u8>, String> {
        let mut env = self.vm.attach_current_thread().map_err(|e| e.to_string())?;
        let method = env
            .new_string(request.method.as_str())
            .map_err(|e| e.to_string())?;
        let url = env
            .new_string(request.url.as_str())
            .map_err(|e| e.to_string())?;
        let string_class = env
            .find_class("java/lang/String")
            .map_err(|e| e.to_string())?;
        let headers = env
            .new_object_array(
                (request.headers.len() * 2) as i32,
                &string_class,
                JObject::null(),
            )
            .map_err(|e| e.to_string())?;
        for (i, (n, v)) in request.headers.iter().enumerate() {
            let (n, v) = (
                env.new_string(n).map_err(|e| e.to_string())?,
                env.new_string(v).map_err(|e| e.to_string())?,
            );
            env.set_object_array_element(&headers, (i * 2) as i32, n)
                .map_err(|e| e.to_string())?;
            env.set_object_array_element(&headers, (i * 2 + 1) as i32, v)
                .map_err(|e| e.to_string())?;
        }
        let body = match &request.body {
            Some(b) => JObject::from(env.byte_array_from_slice(b).map_err(|e| e.to_string())?),
            None => JObject::null(),
        };
        let timeout = request
            .timeout
            .map_or(0, |t| t.as_millis().min(i32::MAX as u128) as i32);
        let out = env
            .call_method(
                &self.bridge,
                "http",
                "(Ljava/lang/String;Ljava/lang/String;[Ljava/lang/String;[BI)[B",
                &[
                    JValue::Object(&method),
                    JValue::Object(&url),
                    JValue::Object(&headers),
                    JValue::Object(&body),
                    JValue::Int(timeout),
                ],
            )
            .and_then(|v| v.l())
            .map_err(|e| {
                let _ = env.exception_clear();
                e.to_string()
            })?;
        env.convert_byte_array(JByteArray::from(out))
            .map_err(|e| e.to_string())
    }

    fn string_call(&self, name: &str, args: &[&str]) -> Option<String> {
        let mut env = self.vm.attach_current_thread().ok()?;
        let js: Vec<JString> = args
            .iter()
            .map(|a| env.new_string(a))
            .collect::<Result<_, _>>()
            .ok()?;
        let vals: Vec<JValue> = js.iter().map(|s| JValue::Object(s)).collect();
        let sig = format!(
            "({})Ljava/lang/String;",
            "Ljava/lang/String;".repeat(args.len())
        );
        let r = env.call_method(&self.bridge, name, &sig, &vals);
        if env.exception_check().unwrap_or(false) {
            let _ = env.exception_clear();
            return None;
        }
        let o = r.ok()?.l().ok()?;
        if o.is_null() {
            return None;
        }
        env.get_string(&JString::from(o)).ok().map(Into::into)
    }

    fn unit_call(&self, name: &str, args: &[&str]) {
        let Ok(mut env) = self.vm.attach_current_thread() else {
            return;
        };
        let Ok(js) = args
            .iter()
            .map(|a| env.new_string(a))
            .collect::<Result<Vec<JString>, _>>()
        else {
            return;
        };
        let vals: Vec<JValue> = js.iter().map(|s| JValue::Object(s)).collect();
        let sig = format!("({})V", "Ljava/lang/String;".repeat(args.len()));
        let _ = env.call_method(&self.bridge, name, &sig, &vals);
        if env.exception_check().unwrap_or(false) {
            let _ = env.exception_clear();
        }
    }
}

struct Http(Arc<Kotlin>);

impl HostHttp for Http {
    fn send(&self, request: HttpRequest) -> Result<HttpResponse, ErrorKind> {
        debug_assert!(matches!(
            request.method,
            Method::Get | Method::Post | Method::Put | Method::Delete
        ));
        match self.0.http(&request) {
            Ok(bytes) => parse_answer(&bytes),
            Err(e) => {
                log::warn!("http bridge: {e}");
                Err(ErrorKind::Network { code: -1005 })
            }
        }
    }
}

struct Secrets(Arc<Kotlin>);

impl SecretStore for Secrets {
    fn get(&self, name: &str) -> Option<String> {
        self.0.string_call("secretGet", &[name])
    }
    fn set(&self, name: &str, value: &str) {
        self.0.unit_call("secretSet", &[name, value]);
    }
    fn remove(&self, name: &str) {
        self.0.unit_call("secretRemove", &[name]);
    }
}

/// `Native.initLive(bridge: Bridge, filesDir: String, cacheDir: String, deviceName: String)`: registers the platform
/// pieces of the real app. Called once, before `create`.
#[unsafe(no_mangle)]
pub extern "system" fn Java_app_swiftly_rustshell_Native_initLive(
    mut env: JNIEnv,
    _class: JClass,
    bridge: JObject,
    files: JString,
    cache: JString,
    device: JString,
) {
    crate::jni_bridge::init_logging();
    let (Ok(vm), Ok(bridge)) = (env.get_java_vm(), env.new_global_ref(&bridge)) else {
        return;
    };
    let text =
        |env: &mut JNIEnv, s: &JString| env.get_string(s).map(String::from).unwrap_or_default();
    let (files, cache, device) = (
        text(&mut env, &files),
        text(&mut env, &cache),
        text(&mut env, &device),
    );
    // Single-threaded start-up: nothing else reads the environment yet.
    unsafe {
        std::env::set_var("SWIFTLY_CONFIG_DIR", &files);
        std::env::set_var("SWIFTLY_CACHE_DIR", &cache);
        std::env::set_var("SWIFTLY_DEVICE_NAME", &device);
    }
    let k = Arc::new(Kotlin { vm, bridge });
    set_host_http(Arc::new(Http(Arc::clone(&k))));
    set_secret_backend(Arc::new(Secrets(k)));
    crate::engine_bridge::register_factory();
}

fn args(env: &mut JNIEnv, list: &[&JString]) -> Vec<String> {
    list.iter()
        .map(|s| env.get_string(s).map(String::from).unwrap_or_default())
        .collect()
}

/// `Native.autologin(address, user, password)`: test runs sign in once before the app starts.
#[unsafe(no_mangle)]
pub extern "system" fn Java_app_swiftly_rustshell_Native_autologin(
    mut env: JNIEnv,
    _class: JClass,
    a: JString,
    u: JString,
    p: JString,
) {
    let v = args(&mut env, &[&a, &u, &p]);
    match swiftly_desktop::live::autologin(&v[0], &v[1], &v[2]) {
        Ok(found) => log::info!("autologin: {found}"),
        Err(e) => log::error!("autologin failed: {e}"),
    }
}

/// `Native.smokePlay(address, user, password, seconds)`: plan, play the fixture clip through Media3, assert the
/// reports; the result lines go to logcat (`SMOKE-PLAY ok` or `SMOKE-PLAY failed`).
#[unsafe(no_mangle)]
pub extern "system" fn Java_app_swiftly_rustshell_Native_smokePlay(
    mut env: JNIEnv,
    _class: JClass,
    a: JString,
    u: JString,
    p: JString,
    secs: jni::sys::jdouble,
) {
    let v = args(&mut env, &[&a, &u, &p]);
    std::thread::spawn(move || {
        match swiftly_desktop::live_play::smoke_play_on(&v[0], &v[1], &v[2], secs, true) {
            Ok(text) => log::info!("SMOKE-PLAY ok\n{text}"),
            Err(e) => log::error!("SMOKE-PLAY failed: {e}"),
        }
    });
}
