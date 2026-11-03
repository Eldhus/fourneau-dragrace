//! The catalog workload: a bigger page from askama, compiled from
//! templates/catalog.html and rendered per request: sections over a record,
//! lists nested in lists, a table of 128 rows, conditions, empty lists, raw
//! HTML and formatting methods. The reference is workloads/catalog.html.

use askama::Template;
use axum::{
    http::{header, StatusCode},
    response::IntoResponse,
};
use std::borrow::Borrow;
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
    offers: Vec<Offer>,
    total: u32,
    groups: Vec<Group>,
    rows: Vec<Row>,
}

struct Shop {
    name: &'static str,
    city: &'static str,
    open: bool,
}

struct Offer {
    what: &'static str,
    off: u8,
}

struct Group {
    name: String,
    members: Vec<&'static str>,
}

struct Row {
    id: u32,
    name: &'static str,
    price: u32,
    discount: u8,
    on_sale: bool,
    stock: i32,
    hot: bool,
    tags: &'static [&'static str],
    added: u16,
    grams: u32,
}

impl Catalog {
    /// A price in hundredths: 12.05.
    fn kr(&self, hundredths: impl Borrow<u32>) -> String {
        let hundredths = *hundredths.borrow();
        format!("{}.{:02}", hundredths / 100, hundredths % 100)
    }

    /// A count and the noun that fits it: 1 group, 6 groups.
    fn plural(&self, count: usize, one: &str, many: &str) -> String {
        format!("{count} {}", if count == 1 { one } else { many })
    }

    /// A percentage: 10%.
    fn pct(&self, percent: &u8) -> String {
        format!("{percent}%")
    }

    /// A stock's level, the row's class: out, low (under ten), ok.
    fn level(&self, stock: &i32) -> &'static str {
        match *stock {
            ..=0 => "out",
            1..10 => "low",
            _ => "ok",
        }
    }

    /// A stock as written: out, 3 left, 16.
    fn stock(&self, count: &i32) -> String {
        match *count {
            ..=0 => "out".to_string(),
            1..10 => format!("{count} left"),
            _ => count.to_string(),
        }
    }

    /// A price after a discount in percent, in hundredths, rounded down.
    fn sale(&self, price: &u32, off: &u8) -> u32 {
        price - price * u32::from(*off) / 100
    }

    /// A day of 2026 (0 is January 1) as MM-DD.
    fn date(&self, day: &u16) -> String {
        chrono::NaiveDate::from_yo_opt(2026, u32::from(*day) + 1).expect("a day of the year").format("%m-%d").to_string()
    }

    /// A weight in grams: 350 g, or 1.25 kg from a kilogram up.
    fn weight(&self, grams: &u32) -> String {
        if *grams < 1000 {
            format!("{grams} g")
        } else {
            format!("{}.{:02} kg", grams / 1000, (grams % 1000) / 10)
        }
    }
}

/// The catalog's names: markup, quotes and accents, each escaped as printed.
const NAMES: [&str; 8] = ["Roux", "Skyr & ber", "Crème", "<b>Stew</b>", "Hákarl", "Kjöt \"s\"", "O'Brien", "Pylsa"];

const TAGS: [&[&str]; 3] = [&[], &["veg"], &["veg", "gf"]];

/// The catalog's data, as race.json's catalog test defines it.
static CATALOG: LazyLock<Catalog> = LazyLock::new(|| {
    let rows: Vec<Row> = (0..128)
        .map(|i: usize| {
            let discount = ((i * 37) % 40) as u8;
            Row {
                id: (i + 1) as u32,
                name: NAMES[i % 8],
                price: (500 + (i * 7919) % 20000) as u32,
                discount,
                on_sale: discount > 0,
                stock: ((i * 13) % 50) as i32 - 10,
                hot: i % 7 == 0,
                tags: TAGS[i % 3],
                added: ((i * 53) % 365) as u16,
                grams: (50 + (i * 997) % 5000) as u32,
            }
        })
        .collect();
    Catalog {
        title: "Catalog <&> \"one\" 'two'",
        note: "<em>Fresh</em> &amp; local",
        currency: "kr",
        shop: Shop { name: "Eldhús", city: "Reykjavík", open: true },
        closed: false,
        specials: Vec::new(),
        offers: vec![
            Offer { what: "Soup of the day", off: 10 },
            Offer { what: "Bread & butter", off: 25 },
            Offer { what: "Coffee <hot>", off: 5 },
        ],
        total: rows.iter().map(|row| row.price).sum(),
        groups: (0..6)
            .map(|k| Group {
                name: format!("Group {}", k + 1),
                members: vec![NAMES[k % 8], NAMES[(k + 1) % 8], NAMES[(k + 2) % 8]],
            })
            .collect(),
        rows,
    }
});

pub async fn catalog() -> impl IntoResponse {
    match CATALOG.render() {
        Ok(page) => ([(header::CONTENT_TYPE, "text/html; charset=utf-8")], page).into_response(),
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}
