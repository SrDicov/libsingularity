void test_list_reads_zoneinfo() {
    if (!FileUtils.test("/usr/share/zoneinfo/zone.tab", FileTest.EXISTS)) {
        Test.skip("no zoneinfo");
        return;
    }
    var zones = Singularity.TimezoneUtil.list();
    assert(zones.length > 100);
    assert("Europe/Rome" in zones);
    foreach (var z in zones) {
        assert(!z.contains("."));
        assert(z != "leapseconds");
    }
    for (int i = 1; i < zones.length; i++) assert(zones[i - 1].collate(zones[i]) <= 0);
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/timezone/list-reads-zoneinfo", test_list_reads_zoneinfo);
    return Test.run();
}
