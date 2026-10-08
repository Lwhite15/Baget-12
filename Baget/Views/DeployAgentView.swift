import SwiftUI

struct DeployAgentView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss

    let prefill: Mission?

    @State private var category: Category? = .fragrance
    @State private var customText = ""
    @State private var name = ""
    @State private var shoeSystem = "US M"
    @State private var shoeSize: Double? = nil
    @State private var topSize = ""
    @State private var pants = ""
    @State private var sizeText = ""
    @State private var keywords = ""
    @State private var traits = ""
    @State private var makers = ""
    @State private var creators = ""
    @State private var voice: Voice = .chill
    @State private var mode: BuyMode = .ask
    @State private var error: String?
    @State private var didPrefill = false
    @State private var icon = Avatar()
    @State private var iconPhoto: UIImage?

    private var info: CategoryInfo { category?.info ?? customMissionInfo }
    private var mission: Mission { category.map { .category($0) } ?? .custom(customText.trimmingCharacters(in: .whitespaces)) }

    private var sizeString: String {
        switch category {
        case .sneakers?: return shoeSize.map { "\(shoeSystem) \(Sizes.display($0))" } ?? ""
        case .apparel?: return [topSize, pants.trimmingCharacters(in: .whitespaces)].filter { !$0.isEmpty }.joined(separator: " · ")
        default: return sizeText.trimmingCharacters(in: .whitespaces)
        }
    }

    private var draft: Agent {
        Agent(id: UUID().uuidString.lowercased(), name: name.trimmingCharacters(in: .whitespaces), mission: mission,
              keywords: TextMatch.list(keywords).map { $0.lowercased() },
              style: StyleProfile(traits: TextMatch.list(traits).map { $0.lowercased() }, makers: TextMatch.list(makers), creators: TextMatch.list(creators)),
              size: sizeString, maxPerItem: 0, monthlyLimit: 0, mode: mode, voice: voice)
    }

    private var shoeOptions: [Double] {
        switch shoeSystem {
        case "EU": return Sizes.euToUSMen.keys.sorted()
        case "UK": return Array(stride(from: 3.0, through: 14.0, by: 0.5))
        case "US W": return Array(stride(from: 5.0, through: 16.5, by: 0.5))
        default: return Array(stride(from: 4.0, through: 15.0, by: 0.5))
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Mission") {
                    FlowRow {
                        ForEach(Category.allCases) { c in
                            Button { category = c } label: { Pill(text: c.info.label, selected: category == c) }.buttonStyle(.plain)
                        }
                        Button { category = nil } label: { Pill(text: "Something else…", selected: category == nil) }.buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                    if category == nil {
                        TextField("What should it hunt? Vinyl, vintage Levi's, Pokémon cards…", text: $customText)
                    }
                }

                Section("Agent") {
                    TextField("Name (optional), e.g. Grail Hunter", text: $name)
                    Picker("How it texts you", selection: $voice) {
                        ForEach(Voice.allCases) { v in Text(v.label).tag(v) }
                    }
                    Text(voice.blurb).font(.caption).foregroundStyle(Theme.muted)
                    Picker("When it finds something", selection: $mode) {
                        ForEach(BuyMode.allCases) { m in Text(m.label).tag(m) }
                    }
                }

                Section {
                    HStack(spacing: 14) {
                        AgentAvatarView(agent: nil, size: 56, preview: icon, previewPhoto: iconPhoto, nameOverride: previewName)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(previewName).font(.headline).foregroundStyle(Theme.ink)
                            Text("Shows on its card and on every text it sends you.").font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                    .padding(.vertical, 2)
                    IconPickerRows(icon: $icon, photo: $iconPhoto)
                } header: { Text("Icon") } footer: {
                    Text("Optional. Use a photo, an emoji, or its initials. You can change it later by tapping the icon on its card.")
                }

                if category == .sneakers {
                    Section {
                        Picker("System", selection: $shoeSystem) {
                            ForEach(["US M", "US W", "UK", "EU"], id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: shoeSystem) { _, _ in shoeSize = nil }
                        Picker("Size", selection: $shoeSize) {
                            Text("Pick a size").tag(Double?.none)
                            ForEach(shoeOptions, id: \.self) { n in Text(Sizes.display(n)).tag(Double?.some(n)) }
                        }
                    } header: { Text("Shoe size (required)") } footer: {
                        Text("Your agent only flags pairs in stock in this size.")
                    }
                } else if category == .apparel {
                    Section {
                        Picker("Top size", selection: $topSize) {
                            Text("Pick a size").tag("")
                            ForEach(Sizes.tops, id: \.self) { Text($0).tag($0) }
                        }
                        TextField("Pants, e.g. 32x32 (optional)", text: $pants)
                    } header: { Text("Clothing size (required)") } footer: {
                        Text("Your agent only flags pieces in stock in this size.")
                    }
                } else if let label = info.sizeLabel {
                    Section(label) { TextField(label, text: $sizeText) }
                }

                Section {
                    TextField("Exact names, models or drops", text: $keywords)
                } header: { Text("Must-have keywords") } footer: { Text("Separate with commas.") }

                Section {
                    LabeledField(label: info.traitsLabel, placeholder: info.traitsPlaceholder, text: $traits)
                    LabeledField(label: info.makersLabel, placeholder: info.makersPlaceholder, text: $makers)
                    LabeledField(label: info.creatorsLabel, placeholder: info.creatorsPlaceholder, text: $creators)
                } header: { Text("\(category == nil ? "" : info.label + " ")style profile") } footer: {
                    Text("Teach it your taste, not just names. It surfaces things that share these traits, even ones you've never heard of.")
                }

                Section {
                    preview
                    if let error { Text(error).foregroundStyle(Theme.hot).font(.footnote) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(LitBackground())
            .navigationTitle("Brief a new agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Deploy") { deploy() }.bold() }
            }
            .onAppear(perform: applyPrefill)
        }
    }

    @ViewBuilder private var preview: some View {
        let a = draft
        if Sizes.required(a) && !Sizes.has(a) {
            Text("Pick your \(category == .sneakers ? "shoe size" : "size") first. Your agent only hunts what's in stock in it.")
                .font(.footnote).foregroundStyle(Theme.warn)
        } else if category == nil && customText.trimmingCharacters(in: .whitespaces).isEmpty {
            Text("Tell this agent what to hunt. Anything works.").font(.footnote).foregroundStyle(Theme.muted)
        } else {
            let k = Matcher.intel(a)
            let reach = Catalog.all.filter { (Matcher.match(a, $0)?.score ?? 0) >= 45 }.count
            let detail = store.isCloud
                ? "it starts searching the web as soon as you deploy it"
                : (reach > 0 ? "would pick up about \(reach) of today's \(Catalog.all.count) sample listings" : "no sample listings fit yet")
            VStack(alignment: .leading, spacing: 6) {
                Text("Taste profile \(k)% complete · \(detail)")
                    .font(.footnote).foregroundStyle(Theme.ink)
                Meter(value: Double(k) / 100)
            }
        }
    }

    private func applyPrefill() {
        guard !didPrefill else { return }
        didPrefill = true
        switch prefill {
        case .category(let c)?: category = c
        case .custom(let text)?: category = nil; customText = text
        case nil: break
        }
    }

    private var previewName: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? String("\(mission.label.capitalizedFirst) Hunter".prefix(40)) : n
    }

    private func deploy() {
        var a = draft
        if case .custom(let t) = a.mission, t.isEmpty { error = "Tell the agent what to hunt."; return }
        if Sizes.required(a) && !Sizes.has(a) { error = "Pick your \(category == .sneakers ? "shoe size" : "size"). This agent only hunts things in stock in your size."; return }
        if a.name.isEmpty { a.name = String("\(a.mission.label.capitalizedFirst) Hunter".prefix(40)) }
        if store.state.agents.count >= 12 { error = "A squad can have up to 12 agents. Retire one to add another."; return }
        // The icon: a photo is kept on the phone now and uploaded once the agent exists.
        var upload: (id: String, jpeg: Data)?
        if icon.style == .photo {
            if let p = iconPhoto, let stored = store.storeIconPhoto(p) {
                upload = stored
                var i = icon
                i.photoID = stored.id
                a.icon = i
            }
        } else if icon != Avatar() {
            var i = icon
            i.photoID = nil
            a.icon = i
        }
        store.deploy(a)
        if store.isCloud {
            let agent = a
            Task { @MainActor in
                let msg = await store.cloudDeploy(agent)
                if let upload, store.agent(agent.id) != nil { store.uploadIconPhoto(id: upload.id, jpeg: upload.jpeg) }
                router.say(msg)
            }
        }
        Analytics.track(.agentDeployed, ["mission": a.mission.category?.rawValue ?? "custom", "intel": Matcher.intel(a),
                                         "mode": a.mode.rawValue, "voice": a.voice.rawValue, "hasSize": !a.size.isEmpty])
        router.deployPrefill = nil
        router.tab = .squad
        if !store.isCloud { router.say("\(a.name) deployed and sweeping") } else { router.say("\(a.name) deployed. Searching the web now…") }
        dismiss()
    }
}

struct LabeledField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(Theme.muted)
            TextField(placeholder, text: $text)
        }
    }
}
