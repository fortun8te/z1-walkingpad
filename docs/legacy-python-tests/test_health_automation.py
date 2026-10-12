from types import SimpleNamespace

from z1_walkingpad_mcp import health_automation


def test_trigger_is_disabled_without_configuration(monkeypatch):
    monkeypatch.delenv(health_automation.ENV_NAME, raising=False)
    assert health_automation.trigger_health_shortcut() is None


def test_trigger_launches_named_shortcut(monkeypatch):
    launched = {}

    def fake_popen(args, **kwargs):
        launched["args"] = args
        launched["kwargs"] = kwargs
        return SimpleNamespace()

    monkeypatch.setenv(health_automation.ENV_NAME, "Z1 Health Trigger")
    monkeypatch.setattr(health_automation.shutil, "which", lambda _: "/usr/bin/shortcuts")
    monkeypatch.setattr(health_automation.subprocess, "Popen", fake_popen)

    assert health_automation.trigger_health_shortcut() == "launched"
    assert launched["args"] == ["/usr/bin/shortcuts", "run", "Z1 Health Trigger"]
