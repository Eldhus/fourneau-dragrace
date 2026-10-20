import Number
import Results

## oha's JSON report (oha 1.16; times in seconds), the part a round keeps.
Oha :: [].{
	## A report as a round: latencies in milliseconds, and the rate counting
	## good answers only.
	round : Str -> Try(Results.Round, [Failed(Str)])
	round = |text| {
		report = parse_report(text) ? |err| Failed("oha output: ${describe(err)}")
		ms = |dict, key| (dict.get(key) ?? Number.Null).or_zero() * 1000
		latency = report.latency_percentiles
		first_byte = report.first_byte_percentiles
		statuses = report.status_code_distribution.to_list()
		errors = report.error_distribution.to_list()
		non_2xx = statuses.keep_if(|(status, _)| !status.starts_with("2")).map(|(_, n)| n).sum()
		# Requests still in flight when the clock runs out are not errors.
		error_count = errors.keep_if(|(kind, _)| kind != "aborted due to deadline").map(|(_, n)| n).sum()
		# Throughput counts good answers only: errors and non-2xx are no work
		# done. oha's rate counts every request that ended, errors too, so it
		# is scaled by the share of good answers among all.
		answered = statuses.map(|(_, n)| n).sum()
		ended = answered + errors.map(|(_, n)| n).sum()
		rate = report.summary.requests_per_sec.or_zero()
		rps = if ended == 0 0 else rate * (answered - non_2xx).to_f64() / ended.to_f64()
		dialup = (report.details.get("DNSDialup") ?? { average: Number.Null }).average.or_zero()
		Ok({
			..Results.zero_round,
			rps,
			success_rate: report.summary.success_rate.or_zero(),
			p50_ms: ms(latency, "p50"),
			p90_ms: ms(latency, "p90"),
			p95_ms: ms(latency, "p95"),
			p99_ms: ms(latency, "p99"),
			p999_ms: ms(latency, "p99.9"),
			p9999_ms: ms(latency, "p99.99"),
			mean_ms: report.summary.average.or_zero() * 1000,
			max_ms: report.summary.slowest.or_zero() * 1000,
			first_byte_p50_ms: ms(first_byte, "p50"),
			first_byte_p99_ms: ms(first_byte, "p99"),
			rps_per_second_stddev: report.rps.stddev.or_zero(),
			connect_mean_ms: dialup * 1000,
			bytes_per_response: report.summary.size_per_request.or_zero(),
			load_seconds: report.summary.total.or_zero(),
			errors: error_count.to_i64_wrap(),
			non_2xx: non_2xx.to_i64_wrap(),
		})
	}
}

Report : {
	summary : { success_rate : Number, requests_per_sec : Number, total : Number, average : Number, slowest : Number, size_per_request : Number },
	rps : { stddev : Number },
	details : Dict(Str, { average : Number }),
	latency_percentiles : Dict(Str, Number),
	first_byte_percentiles : Dict(Str, Number),
	status_code_distribution : Dict(Str, U64),
	error_distribution : Dict(Str, U64),
}

parse_report : Str -> Try(Report, [InvalidJson(Str), MissingRequiredField(Str)])
parse_report = Json.parser_camel()

describe : [InvalidJson(Str), MissingRequiredField(Str)] -> Str
describe = |err|
	match err {
		InvalidJson(why) => why
		MissingRequiredField(field) => "no ${field}"
	}

near : F64, F64 -> Bool
near = |a, b| (a - b).abs() < 1e-9

sample = "{\"summary\":{\"successRate\":1.0,\"total\":2.0,\"slowest\":0.01,\"fastest\":0.0001,\"average\":0.002,\"requestsPerSec\":1000.0,\"totalData\":13000,\"sizePerRequest\":13,\"sizePerSec\":6500},\"responseTimeHistogram\":{\"0.001\":5},\"latencyPercentiles\":{\"p10\":0.001,\"p25\":0.001,\"p50\":0.002,\"p75\":0.002,\"p90\":0.003,\"p95\":0.004,\"p99\":0.005,\"p99.9\":0.008,\"p99.99\":0.009},\"firstBytePercentiles\":{\"p50\":0.001,\"p99\":0.004},\"rps\":{\"mean\":1000,\"stddev\":12.5,\"max\":1100,\"min\":900,\"percentiles\":{\"p50\":1000}},\"details\":{\"DNSDialup\":{\"average\":0.0005,\"fastest\":0.0001,\"slowest\":0.001},\"DNSLookup\":{\"average\":0,\"fastest\":0,\"slowest\":0}},\"statusCodeDistribution\":{\"200\":1500,\"503\":500},\"errorDistribution\":{\"aborted due to deadline\":20}}"

expect {
	match Oha.round(sample) {
		# 1500 good of 2020 ended (the aborted count as ended, as in Go).
		Ok(r) => near(r.rps, 1000 * 1500 / 2020) and r.non_2xx == 500 and r.errors == 0 and near(r.p999_ms, 8) and near(r.connect_mean_ms, 0.5) and r.load_seconds == 2 and r.bytes_per_response == 13
		Err(_) => Bool.False
	}
}

# A dead server: no answers, every percentile null.
expect {
	dead = "{\"summary\":{\"successRate\":0.0,\"total\":1.0,\"slowest\":null,\"fastest\":null,\"average\":null,\"requestsPerSec\":120000.0,\"sizePerRequest\":null},\"latencyPercentiles\":{\"p50\":null,\"p99\":null},\"firstBytePercentiles\":{},\"rps\":{\"stddev\":null},\"details\":{},\"statusCodeDistribution\":{},\"errorDistribution\":{\"connection refused\":120000}}"
	match Oha.round(dead) {
		Ok(r) => r.rps == 0 and r.errors == 120000 and r.p99_ms == 0
		Err(_) => Bool.False
	}
}

expect Oha.round("not json").is_err()
