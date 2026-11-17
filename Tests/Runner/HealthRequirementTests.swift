import Foundation

/// A failed health check must name the requirement it was missing, not only how long it waited.
func healthRequirementTests() {
    // HR1: the service that never came back is named in the rollback's reason and in the timings.
    do {
        let rig = RecipeRig("hr1")
        let app = FakeApp(installed: rig.installed, healthy: ["1.0.0"])
        app.healthRequirement = { expected in
            expected == "1.2.3" ? "service kh.librarystudio.host not running" : nil
        }
        let res = try? rig.run(app).get()
        expect(res?.status == "rolled_back",
               "HR1 an unhealthy new version still rolls back (\(res?.status ?? "nil"))")
        expect(res?.reason?.contains("service kh.librarystudio.host not running") == true,
               "HR1 the rollback names the service that was missing (\(res?.reason ?? "nil"))")
        expect(res?.reason?.contains("not healthy within") == true,
               "HR1 the rollback still says the ceiling it waited (\(res?.reason ?? "nil"))")
        // The timings line travels inside the reason, joined with "; ".
        expect(res?.reason?.contains("timings:") == true
               && res?.reason?.contains("health service kh.librarystudio.host not running") == true,
               "HR1 the timings line carries the same requirement (\(res?.reason ?? "nil"))")
    }

    // HR2: a version mismatch and a stopped app are said in their own words, not as a duration.
    do {
        let rig = RecipeRig("hr2")
        let app = FakeApp(installed: rig.installed, healthy: ["1.0.0"])
        app.healthRequirement = { expected in
            expected == "1.2.3" ? "app not running" : nil
        }
        let res = try? rig.run(app).get()
        expect(res?.reason?.contains("health: app not running") == true,
               "HR2 a stopped app is named plainly (\(res?.reason ?? "nil"))")
        // A check that cannot say more still reports what it knows: the ceiling.
        let rig2 = RecipeRig("hr2b")
        let silent = FakeApp(installed: rig2.installed, healthy: ["1.0.0"])
        let res2 = try? rig2.run(silent).get()
        expect(res2?.reason?.contains("health check did not pass") == true,
               "HR2 a check with no detail still says the check did not pass (\(res2?.reason ?? "nil"))")
    }
}
