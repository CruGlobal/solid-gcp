# frozen_string_literal: true

module SolidGcp
  # View helpers for the cable component. Included into host-app views by the
  # engine so `firestore_stream_from` / `solid_gcp_cable_config_tag` are available
  # everywhere (like turbo-rails' stream helpers).
  module CableHelper
    # Hidden element the Stimulus controller reads to subscribe to a stream doc.
    def firestore_stream_from(*streamables)
      stream_name = Cable::StreamName.from(*streamables)
      doc = "#{SolidGcp.config.cable.collection}/#{Cable::StreamName.doc_id(stream_name)}"

      tag.div(
        hidden: true,
        data: {
          controller: "solid-gcp-cable",
          "solid-gcp-cable-signed-name-value": Cable::StreamName.sign(stream_name),
          "solid-gcp-cable-doc-value": doc
        }
      )
    end

    # JSON config (firebase web config + engine-mounted token path) for the client.
    def solid_gcp_cable_config_tag
      token_path = "#{SolidGcp::MOUNT_PATH}/cable/token"
      cable = SolidGcp.config.cable
      config = emulator_defaults(cable)
        .merge(cable.firebase_web_config)
        .merge("tokenPath" => token_path)

      tag.script(config.to_json.html_safe, type: "application/json", id: "solid-gcp-cable-config")
    end

    private

    # When an emulator host is configured, the client needs the host(s) plus a
    # projectId/apiKey to `initializeApp` (any apiKey works against emulators).
    # Merged under firebase_web_config so explicit web-config keys always win.
    def emulator_defaults(cable)
      firestore_host = cable.firestore_emulator_host
      auth_host = cable.auth_emulator_host
      return {} unless firestore_host || auth_host

      defaults = { "projectId" => cable.project, "apiKey" => "emulator-api-key" }
      defaults["firestoreEmulatorHost"] = firestore_host if firestore_host
      defaults["authEmulatorHost"] = auth_host if auth_host
      defaults
    end
  end
end
