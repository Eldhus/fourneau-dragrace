package main

import "testing"

func TestParseVariant(t *testing.T) {
	v, err := parseVariant("roux:roux=templates-vm,dragrace=abc123")
	if err != nil {
		t.Fatal(err)
	}
	if v.competitor != "roux" || v.refs["roux"] != "templates-vm" || v.refs["dragrace"] != "abc123" ||
		v.refs["fourneau"] != "HEAD" {
		t.Fatalf("parsed %+v", v)
	}
	plain, err := parseVariant("go")
	if err != nil || plain.competitor != "go" || plain.refs["roux"] != "HEAD" {
		t.Fatalf("parsed %+v, %v", plain, err)
	}
	for _, bad := range []string{"roux:rocx=main", "roux:roux", "roux:roux="} {
		if _, err := parseVariant(bad); err == nil {
			t.Errorf("%q: accepted", bad)
		}
	}
}

func TestCompare(t *testing.T) {
	a := &variant{label: "a", competitor: "x", key: "aaaaaaaaaaaa"}
	b := &variant{label: "b", competitor: "x", key: "bbbbbbbbbbbb"}
	run := Run{Race: Race{Workloads: []Workload{{Name: "w"}}}}
	rounds := func(values ...float64) []Round {
		var out []Round
		for _, value := range values {
			out = append(out, Round{RPS: value})
		}
		return out
	}
	run.Results = []Result{
		{Class: "c", Workload: "w", Competitor: a.name(), Valid: true, Rounds: rounds(100, 102, 101)},
		{Class: "c", Workload: "w", Competitor: b.name(), Valid: true, Rounds: rounds(90, 92, 91)},
	}
	for i := range run.Results {
		run.Results[i].summarize()
	}
	labels := map[string]string{a.name(): "a", b.name(): "b"}
	rows := compare(run, "c", []*variant{a, b}, labels)
	if len(rows) != 2 || rows[1].DeltaPct != -9.9 && rows[1].DeltaPct != -9.89 || !rows[1].Apart {
		t.Fatalf("rows %+v", rows)
	}
	run.Results[1].Rounds = rounds(99, 103, 100)
	run.Results[1].summarize()
	rows = compare(run, "c", []*variant{a, b}, labels)
	if rows[1].Apart {
		t.Fatalf("overlapping rounds read apart: %+v", rows[1])
	}
}
