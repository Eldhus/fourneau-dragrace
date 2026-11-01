//! The catalog workload: a bigger page from askama, compiled from
//! templates/catalog.html and rendered per request: sections over a record,
//! lists nested in lists, a table of 256 rows, conditions, empty lists, raw
//! HTML and formatting methods. The reference is workloads/catalog.html.

use askama::Template;
use axum::{
    http::{header, StatusCode},
    response::IntoResponse,
};
use std::sync::LazyLock;

#[derive(Template)]
#[template(path = "catalog.html")]
pub struct Catalog {
    title: &'static str,
    note: &'static str,
    currency: &'static str,
    shop: Shop,
    closed: bool,
    specials: Vec<&'static str>,
    groups: Vec<Group>,
    rows: Vec<Row>,
}

struct Shop {
    name: &'static str,
    city: &'static str,
    open: bool,
}

struct Group {
    name: String,
    members: Vec<&'static str>,
}

struct Row {
    id: u32,
    name: &'static str,
    price: u32,
    stock: i32,
    hot: bool,
    tags: &'static [&'static str],
}

impl Catalog {
    /// A price in hundredths: 12.05.
    fn kr(&self, hundredths: &u32) -> String {
        format!("{}.{:02}", hundredths / 100, hundredths % 100)
    }

    /// A count and the noun that fits it: 1 group, 6 groups.
    fn plural(&self, count: usize, one: &str, many: &str) -> String {
        format!("{count} {}", if count == 1 { one } else { many })
    }
}

/// The catalog's names: markup, quotes and accents, each escaped as printed.
const NAMES: [&str; 8] = ["Roux", "Skyr & ber", "Crème", "<b>Stew</b>", "Hákarl", "Kjöt \"s\"", "O'Brien", "Pylsa"];

const TAGS: [&[&str]; 3] = [&[], &["veg"], &["veg", "gf"]];

/// The catalog's data, as race.json's catalog test defines it.
static CATALOG: LazyLock<Catalog> = LazyLock::new(|| Catalog {
    title: "Catalog <&> \"one\" 'two'",
    note: "<em>Fresh</em> &amp; local",
    currency: "kr",
    shop: Shop { name: "Eldhús", city: "Reykjavík", open: true },
    closed: false,
    specials: Vec::new(),
    groups: (0..6)
        .map(|k| Group {
            name: format!("Group {}", k + 1),
            members: vec![NAMES[k % 8], NAMES[(k + 1) % 8], NAMES[(k + 2) % 8]],
        })
        .collect(),
    rows: (0..256)
        .map(|i: usize| Row {
            id: (i + 1) as u32,
            name: NAMES[i % 8],
            price: (500 + (i * 7919) % 20000) as u32,
            stock: ((i * 13) % 50) as i32 - 10,
            hot: i % 7 == 0,
            tags: TAGS[i % 3],
        })
        .collect(),
});

pub async fn catalog() -> impl IntoResponse {
    match CATALOG.render() {
        Ok(page) => ([(header::CONTENT_TYPE, "text/html; charset=utf-8")], page).into_response(),
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}
