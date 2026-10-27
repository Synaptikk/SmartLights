import Foundation

/// User-facing copy for the WiZ pairing prompts (shared with the onboarding guide).
public enum WiZPairingText {
    public static let signingChoice = """
        This WiZ light only accepts commands signed with your home's security key \
        (WiZ firmware 1.34 or newer with "Only verified controls"). How do you want to continue?
        """

    public static let signingOptions = [
        "Import the key file exported from the WiZ app",
        "Paste the key",
        "Switch the WiZ app to \"Allow all controls\" instead",
    ]

    public static let importFile = """
        In the WiZ app open Home settings > Integrations > Local integrations and export the key. \
        Then pick the downloaded file (it contains "udp_signing_key").
        """

    /// UTType identifiers and extensions accepted for the key export.
    public static let importTypes = ["public.json", "public.plain-text", "json", "txt"]

    public static let pasteKey = """
        Paste the udp_signing_key from the WiZ app export: 32 characters, 0-9 and a-f. \
        You can also paste the whole exported JSON.
        """

    public static let allowAllControls = """
        Open the WiZ app > Settings > Security and set the control mode to "Allow all controls". \
        Your WiZ lights then accept commands from any app on your Wi-Fi without the key. \
        Continue when you have changed the setting.
        """

    public static let keyRejected = """
        The light rejected that key. Make sure you exported the key of the home this light belongs to, \
        and that the key was not rotated since.
        """

    public static let storedKeyRejected = "The saved WiZ key was rejected by this light; it may have been rotated."

    public static let stillUnsigned = """
        The light still rejects unsigned commands. Check the WiZ app setting, or use the key instead.
        """
}
