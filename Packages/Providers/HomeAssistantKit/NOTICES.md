# HomeAssistantKit third-party notices

No third-party code is included. Protocol knowledge and test fixtures come from Home Assistant documentation and
source, both Apache-2.0 (Copyright Home Assistant contributors):

- WebSocket API documentation, https://github.com/home-assistant/developers.home-assistant/blob/master/docs/api/websocket.md
  — example messages copied verbatim into `Tests/HomeAssistantCodecTests/Fixtures/auth_*.json`, `result_call_service.json`,
  `result_subscribe.json`, `pong.json`, `event_state_changed.json`.
- Light entity documentation, https://github.com/home-assistant/developers.home-assistant/blob/master/docs/core/entity/light.md
- `homeassistant/components/light/entity.py`, `const.py` and `homeassistant/components/demo/light.py`
  (https://github.com/home-assistant/core) — attribute names, feature bits and demo entities used to build `get_states.json`.
- `tests/components/config/test_{entity,device,area}_registry.py` (same repository) — registry list key sets used for
  the `*_registry_list.json` fixtures and the inline entity-registry test.
