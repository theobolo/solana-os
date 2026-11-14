import pickle, sys, statistics
# phases of the scenario: (name, start ms, end ms)
PH = [("LIVE", 1500, 6000), ("SCHEDULE live", 6500, 20000), ("SCHEDULE navigation", 20000, 30000), ("GALAXY", 34000, 41000)]
for tag in sys.argv[1:]:
    T = pickle.load(open(tag + "/ws_ticks.pkl", "rb"))
    A = pickle.load(open(tag + "/ws_alloc.pkl", "rb"))
    print(f"== {tag}")
    print(f"{'phase':22s} {'ms/tick':>8s} {'p95':>6s} {'max':>6s} {'>25ms':>6s} {'areas':>6s} {'Kpx/tick':>8s} {'instr/tick':>10s} {'LED/tick':>8s}")
    for n, a, b in PH:
        t = [x for x in T if a <= x[0] < b]
        ms = sorted(x[3] for x in t)
        p95 = ms[int(len(ms) * .95)]
        print(f"{n:22s} {statistics.mean(ms):8.1f} {p95:6.1f} {ms[-1]:6.1f} {100*sum(m > 25 for m in ms)/len(ms):5.0f}% {statistics.mean(x[1] for x in t):6.1f} {statistics.mean(x[2] for x in t)/1000:8.1f} {statistics.mean(x[4] for x in t):10.0f} {statistics.mean(x[5] for x in t):8.1f}")
    print(f"Lua allocation: {statistics.mean(A):.0f} KB/s (max {max(A):.0f})")
