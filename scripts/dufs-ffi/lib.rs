// lib.rs 鈥?FFI wrapper for dufs
// Exposes dufs_start / dufs_stop for embedding in Flutter (dart:ffi)

#[macro_use]
extern crate log;

// Re-export log macros for sub-modules (needed in Rust 2021 edition)
pub(crate) use log::{debug, error, info, trace, warn};

mod args;
mod auth;
mod http_logger;
mod http_utils;
mod logger;
mod noscript;
mod server;
mod utils;

use std::ffi::CStr;
use std::os::raw::c_char;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use crate::args::{build_cli, Args, BindAddr};
use crate::server::Server;
use anyhow::{anyhow, Result};
use std::net::{IpAddr, SocketAddr, TcpListener as StdTcpListener};
use std::time::Duration;

use hyper::{body::Incoming, service::service_fn, Request};
use hyper_util::rt::{TokioExecutor, TokioIo};
use hyper_util::server::conn::auto::Builder;
use socket2::{Domain, Protocol, Socket, Type};
use std::sync::Mutex;

use tokio::net::TcpListener;
use tokio::runtime::Runtime;
use tokio::sync::broadcast;

// All state wrapped in Mutex<Option<T>> so we can reset on stop/start cycles
static RUNNING: Mutex<Option<Arc<AtomicBool>>> = Mutex::new(None);
static RUNTIME: Mutex<Option<Runtime>> = Mutex::new(None);
static SHUTDOWN_TX: Mutex<Option<broadcast::Sender<()>>> = Mutex::new(None);

/// Start the dufs server with argv-style args.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn dufs_start(argc: i32, argv: *const *const c_char) -> i32 {
    // Never let a panic unwind across the C ABI boundary. This cdylib is built
    // with panic="unwind" (Cargo.toml [profile.release]); catch_unwind converts
    // any panic in the startup path into a clean -1 instead of aborting the
    // host application (Flutter on desktop, the foreground Service on Android).
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let argv_vec = unsafe {
            if argc < 0 || argv.is_null() {
                return -1;
            }
            let argc = argc as isize;
            let mut out = Vec::with_capacity(argc as usize);
            for i in 0..argc {
                let ptr = *argv.offset(i);
                if ptr.is_null() {
                    return -1;
                }
                match CStr::from_ptr(ptr).to_str() {
                    Ok(s) => out.push(s.to_owned()),
                    Err(_) => return -1,
                }
            }
            out
        };

        match start_inner(&argv_vec) {
            Ok(_) => 0,
            Err(e) => {
                eprintln!("[dufs-ffi] Failed to start: {e}");
                -1
            }
        }
    }));
    result.unwrap_or_else(|_| {
        eprintln!("[dufs-ffi] panic during start (caught, returning -1)");
        -1
    })
}

/// Stop the dufs server gracefully.
#[no_mangle]
pub extern "C" fn dufs_stop() {
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        if let Ok(mut guard) = RUNNING.lock() {
            if let Some(ref running) = *guard {
                running.store(false, Ordering::SeqCst);
            }
        }
        // Wake up all blocking accept() calls
        if let Ok(mut guard) = SHUTDOWN_TX.lock() {
            if let Some(ref tx) = *guard {
                let _ = tx.send(());
            }
        }
        // Drop runtime to release all resources (listeners, sockets, etc.)
        if let Ok(mut guard) = RUNTIME.lock() {
            *guard = None;
        }
        // Clear statics for next start
        if let Ok(mut guard) = RUNNING.lock() {
            *guard = None;
        }
        if let Ok(mut guard) = SHUTDOWN_TX.lock() {
            *guard = None;
        }
    }));
}

/// Check if the server is running. Returns 1 if running, 0 if not.
#[no_mangle]
pub extern "C" fn dufs_is_running() -> i32 {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        if let Ok(guard) = RUNNING.lock() {
            if let Some(ref running) = *guard {
                if running.load(Ordering::SeqCst) {
                    return 1;
                }
            }
        }
        0
    }))
    .unwrap_or(0)
}

fn start_inner(argv: &[String]) -> Result<()> {
    // Prevent double-start: if a server is already running, stop it first
    {
        let running_guard = RUNNING.lock().map_err(|_| anyhow!("RUNNING lock poisoned"))?;
        if running_guard.is_some() {
            drop(running_guard);
            // Clean up the old server before starting a new one
            dufs_stop();
            std::thread::sleep(Duration::from_millis(200));
        }
    }

    let cmd = build_cli();
    let matches = cmd.try_get_matches_from(argv).map_err(|e| anyhow!("{e}"))?;

    let mut args = Args::parse(matches)?;
    logger::init(args.log_file.clone()).map_err(|e| anyhow!("Failed to init logger, {e}"))?;

    let (new_addrs, _print_addrs) = check_addrs(&args)?;
    args.addrs = new_addrs;

    let running = Arc::new(AtomicBool::new(true));
    if let Ok(mut guard) = RUNNING.lock() {
        *guard = Some(running.clone());
    }

    // Create shutdown channel (capacity 64 for all listener tasks)
    let (shutdown_tx, _) = broadcast::channel::<()>(64);
    if let Ok(mut guard) = SHUTDOWN_TX.lock() {
        *guard = Some(shutdown_tx.clone());
    }

    // Create tokio runtime and set as current (required for tokio::spawn)
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .map_err(|e| anyhow!("Failed to create runtime: {e}"))?;

    let handle = rt.handle().clone();

    // Spawn server tasks on the runtime
    let _handles = handle.block_on(async {
        serve_on_runtime(args, running.clone(), shutdown_tx)
    })?;
    eprintln!("[dufs-ffi] Server started with {} listeners", _handles.len());

    // Keep runtime alive 鈥?move it into static AFTER spawning tasks
    // (RUNTIME is OnceLock, so we set it once)
    if let Ok(mut guard) = RUNTIME.lock() {
        *guard = Some(rt);
    }
    // Note: handles are now running on the stored runtime.
    // We don't need to join them 鈥?they run until the process exits or running=false.

    // Monitor thread: poll running flag, print when stopped
    std::thread::spawn(move || {
        while running.load(Ordering::SeqCst) {
            std::thread::sleep(Duration::from_millis(500));
        }
        eprintln!("[dufs-ffi] Server stopping...");
    });

    Ok(())
}

fn serve_on_runtime(
    args: Args,
    running: Arc<AtomicBool>,
    shutdown_tx: broadcast::Sender<()>,
) -> Result<Vec<tokio::task::JoinHandle<()>>> {
    let addrs = args.addrs.clone();
    let port = args.port;
    let server_handle = Arc::new(Server::init(args, running)?);
    let mut handles = vec![];

    for bind_addr in addrs.iter() {
        let server_handle = server_handle.clone();
        match bind_addr {
            BindAddr::IpAddr(ip) => {
                let mut listener = create_listener(SocketAddr::new(*ip, port))?;
                let mut shutdown_rx = shutdown_tx.subscribe();
                let handle = tokio::spawn(async move {
                    loop {
                        tokio::select! {
                            result = listener.accept() => {
                                if let Ok((stream, addr)) = result {
                                    let stream = TokioIo::new(stream);
                                    tokio::spawn(handle_stream(server_handle.clone(), stream, Some(addr)));
                                }
                            }
                            _ = shutdown_rx.recv() => break,
                        }
                    }
                });
                handles.push(handle);
            }
            #[cfg(unix)]
            BindAddr::SocketPath(path) => {
                let socket_path = if path.starts_with("@")
                    && cfg!(any(target_os = "linux", target_os = "android"))
                {
                    let mut path_buf = path.as_bytes().to_vec();
                    path_buf[0] = b'\0';
                    unsafe { std::ffi::OsStr::from_encoded_bytes_unchecked(&path_buf) }
                        .to_os_string()
                } else {
                    let _ = std::fs::remove_file(path);
                    path.into()
                };
                let mut listener = tokio::net::UnixListener::bind(socket_path)?;
                let mut shutdown_rx = shutdown_tx.subscribe();
                let handle = tokio::spawn(async move {
                    loop {
                        tokio::select! {
                            result = listener.accept() => {
                                if let Ok((stream, _addr)) = result {
                                    let stream = TokioIo::new(stream);
                                    tokio::spawn(handle_stream(server_handle.clone(), stream, None));
                                }
                            }
                            _ = shutdown_rx.recv() => break,
                        }
                    }
                });
                handles.push(handle);
            }
        }
    }
    Ok(handles)
}

async fn handle_stream<T>(
    handle: Arc<Server>,
    stream: TokioIo<T>,
    addr: Option<SocketAddr>,
) where
    T: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    let hyper_service =
        service_fn(move |request: Request<Incoming>| handle.clone().call(request, addr));

    let _ = Builder::new(TokioExecutor::new())
        .serve_connection_with_upgrades(stream, hyper_service)
        .await;
}

fn create_listener(addr: SocketAddr) -> Result<TcpListener> {
    use std::thread;
    use std::time::Duration;

    // Retry bind up to 8 times with increasing delays (handles TIME_WAIT on Windows)
    let mut last_err = None;
    for attempt in 0..8 {
        let socket = Socket::new(Domain::for_address(addr), Type::STREAM, Some(Protocol::TCP))?;
        if addr.is_ipv6() {
            socket.set_only_v6(true)?;
        }
        socket.set_reuse_address(true)?;
        // On non-Windows, also set SO_REUSEPORT for faster rebinding
        #[cfg(unix)]
        {
            let _ = socket.set_reuse_port(true);
        }
        // Set linger=0 to avoid TIME_WAIT on close
        let _ = socket.set_linger(Some(Duration::from_secs(0)));
        match socket.bind(&addr.into()) {
            Ok(()) => {
                socket.listen(1024)?;
                let std_listener = StdTcpListener::from(socket);
                std_listener.set_nonblocking(true)?;
                let listener = TcpListener::from_std(std_listener)?;
                return Ok(listener);
            }
            Err(e) => {
                last_err = Some(e);
                if attempt < 7 {
                    let delay = 200 * (attempt + 1) as u64;
                    eprintln!("[dufs-ffi] bind {} failed (attempt {}), retrying in {}ms...",
                        addr, attempt + 1, delay);
                    thread::sleep(Duration::from_millis(delay));
                }
            }
        }
    }
    anyhow::bail!("Failed to bind {} after 8 attempts: {:?}", addr, last_err)
}

fn check_addrs(args: &Args) -> Result<(Vec<BindAddr>, Vec<BindAddr>)> {
    let mut new_addrs = vec![];
    let mut print_addrs = vec![];
    let (ipv4_addrs, ipv6_addrs) = interface_addrs()?;
    for bind_addr in args.addrs.iter() {
        match bind_addr {
            BindAddr::IpAddr(ip) => match &ip {
                IpAddr::V4(_) => {
                    if !ipv4_addrs.is_empty() {
                        new_addrs.push(bind_addr.clone());
                        if ip.is_unspecified() {
                            print_addrs.extend(ipv4_addrs.clone());
                        } else {
                            print_addrs.push(bind_addr.clone());
                        }
                    }
                }
                IpAddr::V6(_) => {
                    if !ipv6_addrs.is_empty() {
                        new_addrs.push(bind_addr.clone());
                        if ip.is_unspecified() {
                            print_addrs.extend(ipv6_addrs.clone());
                        } else {
                            print_addrs.push(bind_addr.clone())
                        }
                    }
                }
            },
            #[cfg(unix)]
            _ => {
                new_addrs.push(bind_addr.clone());
                print_addrs.push(bind_addr.clone())
            }
        }
    }
    print_addrs.sort_unstable();
    Ok((new_addrs, print_addrs))
}

fn interface_addrs() -> Result<(Vec<BindAddr>, Vec<BindAddr>)> {
    let (mut ipv4_addrs, mut ipv6_addrs) = (vec![], vec![]);
    let ifaces = if_addrs::get_if_addrs()?;
    for iface in ifaces.into_iter() {
        let ip = iface.ip();
        if ip.is_ipv4() {
            ipv4_addrs.push(BindAddr::IpAddr(ip))
        }
        if ip.is_ipv6() {
            ipv6_addrs.push(BindAddr::IpAddr(ip))
        }
    }
    Ok((ipv4_addrs, ipv6_addrs))
}
