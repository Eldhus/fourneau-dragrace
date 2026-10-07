package main

import (
	"strings"
	"testing"
)

func TestMixedStepAddsRatesAndWeighsTheMean(t *testing.T) {
	step := mixedStep(1000, []OpenPart{
		{Name: "list", AchievedRPS: 500, MeanMs: 2, P99Ms: 9},
		{Name: "comment", AchievedRPS: 500, MeanMs: 4, P99Ms: 12, Errors: 1},
	})
	if step.AchievedRPS != 1000 || step.MeanMs != 3 || step.P99Ms != 12 || step.Errors != 1 {
		t.Fatalf("%+v", step)
	}
	if empty := mixedStep(1000, []OpenPart{{Name: "list"}}); empty.MeanMs != 0 {
		t.Fatalf("no answers, a mean of %v", empty.MeanMs)
	}
}

// The contract's checks name where an answer differs from the model.
func TestDescribeDifferenceNamesThePlace(t *testing.T) {
	model := newConduitModel()
	want := model.list(20, 0)
	got := model.list(20, 0)
	if why := describeDifference(got, want); why != "" {
		t.Fatalf("the same: %s", why)
	}
	got["articles"].([]any)[3].(map[string]any)["favoritesCount"] = 99.0
	if why := describeDifference(got, want); !strings.Contains(why, ".articles[3].favoritesCount") {
		t.Fatalf("a count changed: %q", why)
	}
	got = model.list(20, 0)
	got["articles"].([]any)[0].(map[string]any)["body"] = "x"
	if why := describeDifference(got, want); !strings.Contains(why, "body: not in the contract") {
		t.Fatalf("a body in the list: %q", why)
	}
	got = model.list(19, 0)
	if why := describeDifference(got, want); !strings.Contains(why, "want 20 items") {
		t.Fatalf("a short list: %q", why)
	}
}

func TestPartCommandIsOpenLoopWithTheLoadUsersToken(t *testing.T) {
	race := Race{Port: 8080}
	target := Target{Address: "10.0.0.2", LoaderHome: "/root/l", LoaderThreads: 8}
	workload := Workload{Connections: 256}
	command := partCommand(race, workload, target, Part{Name: "comment", Method: "POST",
		Path: "/api/articles/article-0[0-9]{3}/comments", Share: 0.15, Auth: true,
		Body: `{"comment":{"body":"x"}}`}, 150, 10)
	for _, want := range []string{"-q 150 --latency-correction", "-c 39", "--worker-threads 2",
		"-m POST", "Authorization: Token " + conduitToken(conduitLoadUser), "--rand-regex-url",
		"http://10[.]0[.]0[.]2:8080/api/articles/article-0[0-9]{3}/comments"} {
		if !strings.Contains(command, want) {
			t.Fatalf("no %q in %s", want, command)
		}
	}
}
