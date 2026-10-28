using Singularity;

void test_form_factor () {
    assert (AudioManager.is_headphones ("headphones", null, "Sony WH-1000XM4"));
    assert (AudioManager.is_headphones ("headset", null, null));
    assert (AudioManager.is_headphones ("hands-free", null, null));
    assert (!AudioManager.is_headphones ("speaker", "headphone-output", "Headphone Speaker"));
    assert (!AudioManager.is_headphones ("tv", null, "LG TV"));
}

void test_jack () {
    assert (AudioManager.is_headphones ("internal", "analog-output-headphones", "Built-in Audio Analog Stereo"));
    assert (!AudioManager.is_headphones ("internal", "analog-output-speaker", "Built-in Audio Analog Stereo"));
    assert (!AudioManager.is_headphones (null, "hdmi-output-0", "HDMI / DisplayPort"));
}

void test_name () {
    assert (AudioManager.is_headphones (null, "analog-output", "USB-C to 3.5mm Headphone Jack Adapter Analog Stereo"));
    assert (AudioManager.is_headphones (null, null, "Galaxy Buds2 Pro"));
    assert (AudioManager.is_headphones (null, null, "AirPods Pro"));
    assert (!AudioManager.is_headphones (null, "analog-output", "USB Audio Analog Stereo"));
    assert (!AudioManager.is_headphones (null, null, null));
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/audio-output/form-factor", test_form_factor);
    Test.add_func ("/audio-output/jack", test_jack);
    Test.add_func ("/audio-output/name", test_name);
    return Test.run ();
}
