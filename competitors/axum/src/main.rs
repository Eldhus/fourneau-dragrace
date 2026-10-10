//! The axum competitor: axum::serve on tokio's multi-threaded runtime.
//! TCP_NODELAY is set on accepted sockets, as axum's docs show
//! (`ListenerExt::tap_io`); without it, pipelined responses wait 40 ms on
//! delayed ACKs. See README.md for what you may tune.

mod conduit;

use askama::Template;
use std::convert::Infallible;

use axum::{
    body::Bytes,
    extract::Query,
    http::{header, StatusCode},
    response::{
        sse::{Event, Sse},
        IntoResponse,
    },
    routing::{get, post},
    serve::ListenerExt,
    Router,
};

/// The templates workload: askama, compiled from templates/menu.html,
/// rendered per request (it escapes every value as HTML).
#[derive(Template)]
#[template(path = "menu.html")]
struct Menu<'a> {
    dishes: &'a [Dish],
}

struct Dish {
    name: &'static str,
    price: u32,
}

const DISHES: [Dish; 12] = [
    Dish { name: "Roux", price: 120 },
    Dish { name: "Fish & chips", price: 290 },
    Dish { name: "Crème brûlée", price: 180 },
    Dish { name: "<b>Bold</b> stew", price: 240 },
    Dish { name: "Skyr & berries", price: 150 },
    Dish { name: "Hákarl", price: 990 },
    Dish { name: "Plokkfiskur", price: 310 },
    Dish { name: "Kjötsúpa", price: 270 },
    Dish { name: "Rúgbrauð <warm>", price: 90 },
    Dish { name: "Pylsa með öllu", price: 120 },
    Dish { name: "Flatkaka & hangikjöt", price: 210 },
    Dish { name: "1 < 2 > 0 pie", price: 160 },
];

async fn menu() -> impl IntoResponse {
    match (Menu { dishes: &DISHES }).render() {
        Ok(page) => ([(header::CONTENT_TYPE, "text/html; charset=utf-8")], page).into_response(),
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

/// The SSE workload: a Datastar action. Its signals are JSON in the
/// `datastar` query parameter (a missing one is axum's 400); the answer is
/// a stream of Datastar events through axum's `Sse`.
#[derive(serde::Deserialize)]
struct DatastarQuery {
    datastar: String,
}

#[derive(serde::Deserialize)]
struct Signals {
    count: u32,
}

async fn datastar(Query(query): Query<DatastarQuery>) -> axum::response::Response {
    let Ok(signals) = serde_json::from_str::<Signals>(&query.datastar) else {
        return (StatusCode::BAD_REQUEST, "bad signals").into_response();
    };
    let count = u64::from(signals.count) + 1;
    let mut events = vec![
        Event::default()
            .event("datastar-patch-signals")
            .data(format!("signals {{\"count\":{count}}}")),
        Event::default()
            .event("datastar-patch-elements")
            .data(format!("elements <span id=\"count\">{count}</span>")),
    ];
    for line in 1..=8 {
        events.push(Event::default().event("datastar-patch-elements").data(format!(
            "selector #log\nmode append\nelements <li>Event {line} of 8</li>"
        )));
    }
    let stream = futures_util::stream::iter(events.into_iter().map(Ok::<_, Infallible>));
    Sse::new(stream).into_response()
}

async fn plaintext() -> impl IntoResponse {
    ([(header::CONTENT_TYPE, "text/plain; charset=utf-8")], "Hello, World!")
}

async fn echo(body: Bytes) -> impl IntoResponse {
    ([(header::CONTENT_TYPE, "application/octet-stream")], body)
}

fn argument(name: &str, default: &str) -> String {
    let args: Vec<String> = std::env::args().collect();
    args.iter()
        .position(|a| a == name)
        .and_then(|i| args.get(i + 1).cloned())
        .unwrap_or_else(|| default.to_string())
}

/// HTTPS, as the race asks of every competitor (RACING.md, TLS): TLS 1.3,
/// X25519, no session resumption, HTTP/2 by ALPN. A task per connection,
/// TCP_NODELAY as on plain HTTP; the handshake in that task.
async fn serve_tls(listener: tokio::net::TcpListener, app: Router, cert: &str, key: &str) {
    use rustls_pki_types::{pem::PemObject, CertificateDer, PrivateKeyDer};
    use std::sync::Arc;
    use tokio_rustls::rustls;
    let certs = CertificateDer::pem_file_iter(cert)
        .expect("--tls-cert")
        .collect::<Result<Vec<_>, _>>()
        .expect("--tls-cert");
    let key = PrivateKeyDer::from_pem_file(key).expect("--tls-key");
    let mut provider = rustls::crypto::aws_lc_rs::default_provider();
    provider.kx_groups = vec![rustls::crypto::aws_lc_rs::kx_group::X25519];
    // AES-128-GCM, as Go's server and browsers choose: rustls follows the
    // client's order, and oha's puts AES-256-GCM first.
    provider.cipher_suites = vec![
        rustls::crypto::aws_lc_rs::cipher_suite::TLS13_AES_128_GCM_SHA256,
        rustls::crypto::aws_lc_rs::cipher_suite::TLS13_CHACHA20_POLY1305_SHA256,
    ];
    let mut config = rustls::ServerConfig::builder_with_provider(Arc::new(provider))
        .with_protocol_versions(&[&rustls::version::TLS13])
        .expect("TLS 1.3")
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .expect("the certificate and key");
    config.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
    config.session_storage = Arc::new(rustls::server::NoServerSessionStorage {});
    config.send_tls13_tickets = 0;
    let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(config));
    let service = hyper_util::service::TowerToHyperService::new(app);
    loop {
        let Ok((tcp, _)) = listener.accept().await else { continue };
        let _ = tcp.set_nodelay(true);
        let (acceptor, service) = (acceptor.clone(), service.clone());
        tokio::spawn(async move {
            let Ok(tls) = acceptor.accept(tcp).await else { return };
            let builder =
                hyper_util::server::conn::auto::Builder::new(hyper_util::rt::TokioExecutor::new());
            let io = hyper_util::rt::TokioIo::new(tls);
            let _ = builder.serve_connection(io, service).await;
        });
    }
}

#[tokio::main]
async fn main() {
    let address = argument("--address", "127.0.0.1");
    let port: u16 = argument("--port", "8080").parse().expect("--port");
    let database = argument("--database", "");
    let mut app = Router::new()
        .route("/plaintext", get(plaintext))
        .route("/echo", post(echo))
        .route("/menu", get(menu))
        .route("/sse", get(datastar))
        .layer(axum::extract::DefaultBodyLimit::max(1 << 20));
    if !database.is_empty() {
        let conduit = conduit::open(&database).await.expect("--database");
        app = app.merge(conduit::routes(conduit));
    }
    let listener = tokio::net::TcpListener::bind((address.as_str(), port)).await.unwrap();
    let tls_cert = argument("--tls-cert", "");
    if !tls_cert.is_empty() {
        println!("axum on https://{address}:{port}");
        serve_tls(listener, app, &tls_cert, &argument("--tls-key", "")).await;
        return;
    }
    println!("axum on http://{address}:{port}");
    let listener = listener.tap_io(|tcp| {
        let _ = tcp.set_nodelay(true);
    });
    axum::serve(listener, app).await.unwrap();
}
