package main

import (
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
)

// A local race pins the server and the loader to CPUs (race.json's
// "local"). Logical CPUs are not cores: two hyperthreads of one core
// share its execution units, so a server CPU whose sibling the loader
// has is not the server's alone. The numbering differs between machines
// (0-1 one core on the owner's laptop; 0 and 4 one core elsewhere), so
// the race checks it before it trusts it.

// coreOf names a logical CPU's physical core, "package:core".
type coreOf func(cpu string) (string, error)

func sysfsCore(cpu string) (string, error) {
	read := func(name string) (string, error) {
		bytes, err := os.ReadFile("/sys/devices/system/cpu/cpu" + cpu + "/topology/" + name)
		return strings.TrimSpace(string(bytes)), err
	}
	pkg, err := read("physical_package_id")
	if err != nil {
		return "", err
	}
	core, err := read("core_id")
	if err != nil {
		return "", err
	}
	return pkg + ":" + core, nil
}

// checkCoresApart fails when a physical core has CPUs in both sets.
func checkCoresApart(serverCPUs, loaderCPUs string, core coreOf) error {
	cores := func(cpus string) (map[string][]string, error) {
		found := map[string][]string{}
		for cpu := range cpuSet(cpus) {
			name, err := core(cpu)
			if err != nil {
				return nil, fmt.Errorf("CPU %s: %w", cpu, err)
			}
			found[name] = append(found[name], cpu)
		}
		return found, nil
	}
	server, err := cores(serverCPUs)
	if err != nil {
		return err
	}
	loader, err := cores(loaderCPUs)
	if err != nil {
		return err
	}
	var shared []string
	for name, cpus := range server {
		if others, found := loader[name]; found {
			sort.Strings(cpus)
			sort.Strings(others)
			shared = append(shared, fmt.Sprintf("core %s: server %s, loader %s", name,
				strings.Join(cpus, ","), strings.Join(others, ",")))
		}
	}
	if len(shared) > 0 {
		sort.Strings(shared)
		return fmt.Errorf("server CPUs %s and loader CPUs %s share physical cores (%s): "+
			"pick whole cores for each (lscpu -e=CPU,CORE)", serverCPUs, loaderCPUs,
			strings.Join(shared, "; "))
	}
	return nil
}

func cpuNumber(cpu string) int {
	number, _ := strconv.Atoi(cpu)
	return number
}
