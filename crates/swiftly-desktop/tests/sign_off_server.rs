//! Signing an account out tells its server (`removeAndSignOff`): `POST Sessions/Logout` with the account's own token.
//! A local socket plays the server. Runs in a child process with a temporary `SWIFTLY_CONFIG_DIR` (file secrets).
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::io::{Read, Write};
use std::net::TcpListener;
use swiftly_accounts::{Account, AccountBundle, ServerBundles, save_bundles};
use swiftly_desktop::live::Core;
use swiftly_jellyfin::{ServerKind, Session};

#[test]
fn signing_out_logs_the_token_out_at_the_server() {
    if std::env::var_os("SWIFTLY_CONFIG_DIR").is_none() {
        let dir = std::env::temp_dir().join(format!("swiftly-sign-off-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let me = std::env::current_exe().expect("exe");
        let out = std::process::Command::new(me)
            .args([
                "--exact",
                "signing_out_logs_the_token_out_at_the_server",
                "--nocapture",
                "--test-threads=1",
            ])
            .env("SWIFTLY_CONFIG_DIR", &dir)
            .output()
            .expect("child");
        let _ = std::fs::remove_dir_all(&dir);
        assert!(
            out.status.success(),
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        return;
    }
    let listener = TcpListener::bind("127.0.0.1:0").expect("port");
    let url = format!("http://{}", listener.local_addr().expect("addr"));
    let (tx, rx) = std::sync::mpsc::channel::<String>();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut buf = [0u8; 4096];
            let n = stream.read(&mut buf).unwrap_or(0);
            let _ = tx.send(String::from_utf8_lossy(&buf[..n]).into_owned());
            let _ = stream.write_all(
                b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            );
        }
    });
    let core = Core::open().expect("core");
    let session = Session {
        access_token: "tok-anna".into(),
        user_id: "id-anna".into(),
        user_name: "anna".into(),
        server_url: url,
        kind: ServerKind::Jellyfin,
    };
    save_bundles(
        &*core.secrets,
        &ServerBundles::new(
            vec![(
                ServerKind::Jellyfin,
                AccountBundle::new(Account::new(session)),
            )],
            ServerKind::Jellyfin,
        ),
    );
    let key = core.accounts_list()[0].key.clone();
    core.sign_out_account(&key);
    assert!(core.accounts_list().is_empty(), "gone locally at once");
    let request = rx
        .recv_timeout(std::time::Duration::from_secs(5))
        .expect("the server was told");
    assert!(request.starts_with("POST /Sessions/Logout"), "{request}");
    assert!(
        request.contains("tok-anna"),
        "the account's own token: {request}"
    );
}
