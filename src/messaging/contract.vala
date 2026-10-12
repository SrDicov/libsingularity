namespace Singularity.Messaging {

    public static bool installed() {
        return Capabilities.available(Contracts.MESSAGES);
    }

    public static void open_conversation(string channel, string conversation) {
        Capabilities.call_and_forget(Contracts.MESSAGES, "OpenConversation", new Variant("(ss)", channel, conversation));
    }

    public static void compose(string person, string address, string text) {
        Capabilities.call_and_forget(Contracts.MESSAGES, "Compose", new Variant("(sss)", person, address, text));
    }

    public static async void send(string channel, string conversation, string text) throws Error {
        yield Capabilities.call(Contracts.MESSAGES, "Send", new Variant("(sss)", channel, conversation, text), null);
    }
}
