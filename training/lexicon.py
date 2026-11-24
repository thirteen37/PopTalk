"""Word banks for gen.py (#21). Everything here is written for training; none of it comes from
bench/cases.jsonl, and contamination.py rejects any example that drifts toward a bench case."""

# People: (written form, misheard/phonetic forms a recognizer or typist might produce).
PEOPLE = [
    ("Siobhan", ["shivawn", "shevon"]), ("Niamh", ["neve", "neeve"]), ("Saoirse", ["sirsha", "seersha"]),
    ("Xochitl", ["sochil", "sochi"]), ("Thuy", ["twee"]), ("Oluwaseun", ["olu washay", "oluwashaun"]),
    ("Chidi", ["cheedy"]), ("Ngozi", ["gozi", "n gozi"]), ("Bogdan", ["bogdon"]), ("Wojciech", ["voytek", "voy check"]),
    ("Grzegorz", ["gregor", "gzegosh"]), ("Joaquín", ["wakeen", "joaquin"]), ("Ximena", ["himena", "ximina"]),
    ("Anaïs", ["anais", "anna ease"]), ("Søren", ["soren", "sorin"]), ("Bjørn", ["byorn", "bjorn"]),
    ("Ingrid", ["ingred"]), ("Mihai", ["mihigh", "me high"]), ("Ioana", ["yoana", "joanna"]),
    ("Tadhg", ["tige", "taig"]), ("Aoife", ["eefa", "eva"]), ("Rhys", ["reese", "rees"]),
    ("Dmitri", ["dimitri", "dmitry"]), ("Yevgenia", ["evgenia", "eugenia"]), ("Kwame", ["kwamee"]),
    ("Abena", ["abina"]), ("Ifeoma", ["ifioma", "ife oma"]), ("Tendai", ["ten die"]), ("Rutendo", ["rutendoh"]),
    ("Lakshmi", ["luxmi", "lakshmee"]), ("Harpreet", ["harprit"]), ("Gurpreet", ["gurprit"]), ("Mehmet", ["mehmed", "mehmat"]),
    ("Elif", ["eleaf"]), ("Dilnoza", ["dil nosa"]), ("Leilani", ["lay lani", "leilanie"]), ("Thandiwe", ["tandiway", "thandi way"]),
    ("Sipho", ["see po"]), ("Zainab", ["zaynab"]), ("Yusuf", ["yousef", "yusef"]), ("Shirin", ["shereen"]),
    ("Darius", ["dariush"]), ("Mateus", ["matayus", "mateos"]), ("Raphaël", ["rafael", "raphael"]), ("Céline", ["celine", "selene"]),
    ("Henrike", ["henrika"]), ("Linnea", ["linnay", "linea"]), ("Paavo", ["pavo"]), ("Aino", ["eye no", "ayno"]),
    ("Haruto", ["haroto"]), ("Seo-yeon", ["so yun", "seoyeon"]), ("Jae-won", ["jay won", "jaewon"]), ("Linh", ["lin"]),
    ("Kavya", ["kavia"]), ("Rohan", ["rowan"]), ("Deepika", ["deepeeka"]), ("Anwen", ["an when"]), ("Eilidh", ["ailey", "aylee"]),
    ("Caoimhe", ["keeva", "kweeva"]), ("Bronagh", ["brona"]), ("Ruairí", ["rory", "ruairi"]), ("Zbigniew", ["zbignev", "big new"]),
    ("Jolanta", ["yolanta"]), ("Agnieszka", ["agnieshka", "ag nyeshka"]), ("Kiri", ["kiree"]), ("Mahina", ["maheena"]),
    ("Olamide", ["ola mee day"]), ("Chiamaka", ["chee amaka"]), ("Eszter", ["ester"]), ("Zsófia", ["sofia", "zofia"]),
    ("Gwendolyn", ["gwendolin"]), ("Ffion", ["fion"]), ("Teodora", ["theodora"]), ("Nikolai", ["nicolai"]),
    ("Viktorija", ["victoria"]), ("Bartholomew", ["bartholomeu"]), ("Ottilie", ["ottily", "otilee"]),
]

SURNAMES = [
    ("Okonkwo", ["okonkwoh", "o conquo"]), ("Nakamura", ["naka mura"]), ("Kowalczyk", ["kovalchick", "kowal chick"]),
    ("Fitzgerald", ["fitz gerald"]), ("Haddad", ["hadad"]), ("Lindqvist", ["lindkvist", "lindquist"]),
    ("Abernathy", ["abernethy"]), ("Papadopoulos", ["papa dopolous", "papadopolis"]), ("Szymański", ["shimanski", "szymanski"]),
    ("Delacroix", ["della qua", "delacrwa"]), ("Vasquez", ["vaskez", "vasques"]), ("Iyer", ["eye er", "iyer"]),
    ("Chakraborty", ["chakra borty", "chakrabarti"]), ("Bhattacharya", ["bhatta charya", "batacharia"]), ("Nwosu", ["nuosu", "wosu"]),
    ("Achterberg", ["ackterberg", "achter berg"]), ("Gallagher", ["gallager", "galaher"]), ("McAllister", ["mack alister", "mcalister"]),
    ("Rasmussen", ["rasmusen"]), ("Toivonen", ["toy vonen"]), ("Brzezinski", ["bzhezinski", "brezinski"]),
    ("Dąbrowski", ["dombrowski", "dabrowski"]), ("Al-Masri", ["al masri", "almasri"]), ("Takahashi", ["taka hashi"]),
    ("Lefebvre", ["lefev", "lefeb"]), ("Moreau", ["moro", "morrow"]), ("Schmidt-Hoffmann", ["schmidt hoffman", "smith hoffman"]),
    ("Oyekunle", ["oye kunle"]), ("Ramaswamy", ["rama swamy"]), ("Ó Briain", ["o brien", "obrien"]),
    ("Featherstonehaugh", ["fanshaw", "feather stone haw"]), ("Czerwinski", ["chervinski", "zerwinski"]),
    ("Nguyen-Tran", ["win tran", "nguyen tran"]), ("Van Achteren", ["van ackteren"]), ("Kristiansen", ["christiansen"]),
    ("Mbatha", ["em batha", "batha"]), ("Quiñones", ["kinyones", "quinones"]), ("Hølmebakk", ["holm a back", "holmebakk"]),
]

# Real tools and jargon: (written form, misheard/split forms).
TECH = [
    ("Terraform", ["terra form"]), ("Grafana", ["gra fana", "grafanna"]), ("Prometheus", ["promethius"]),
    ("PostgreSQL", ["postgres q l", "post gress sequel"]), ("pgvector", ["pg vector", "p g vector"]), ("Supabase", ["supa base", "super base"]),
    ("Vercel", ["versel", "vercell"]), ("Netlify", ["net lify", "netlifi"]), ("Cloudflare", ["cloud flare"]),
    ("Datadog", ["data dog"]), ("PagerDuty", ["pager duty"]), ("Sentry", ["sentry"]), ("Figma", ["figma", "fig ma"]),
    ("Airtable", ["air table"]), ("Zapier", ["zappier", "zap ear"]), ("Obsidian", ["obsidian"]), ("Raycast", ["ray cast"]),
    ("Xcode", ["x code", "ex code"]), ("SwiftUI", ["swift ui", "swift u i"]), ("Core Data", ["core data"]), ("PyTorch", ["pie torch", "py torch"]),
    ("NumPy", ["num pie", "numpy"]), ("pandas", ["pandas"]), ("scikit-learn", ["sci kit learn", "psychic learn"]),
    ("LangChain", ["lang chain"]), ("Redis", ["reddis", "red is"]), ("Kafka", ["kafka"]), ("RabbitMQ", ["rabbit m q", "rabbit mq"]),
    ("Elasticsearch", ["elastic search"]), ("Snowflake", ["snow flake"]), ("BigQuery", ["big query"]), ("dbt", ["d b t", "dbt"]),
    ("Airflow", ["air flow"]), ("Dagster", ["dag ster", "dagster"]), ("Jupyter", ["jupiter"]), ("VS Code", ["vs code", "v s code"]),
    ("Neovim", ["neo vim", "neo vim"]), ("GitHub Actions", ["github actions", "git hub actions"]), ("GitLab", ["git lab"]),
    ("CircleCI", ["circle c i", "circle ci"]), ("Argo CD", ["argo c d", "argo cd"]), ("Helm", ["helm"]), ("Istio", ["is tio", "istio"]),
    ("nginx", ["engine x", "n ginx"]), ("Docker", ["docker"]), ("WebAssembly", ["web assembly"]), ("GraphQL", ["graph q l", "graph ql"]),
    ("gRPC", ["g r p c", "grpc"]), ("OAuth", ["o auth", "oh auth"]), ("Okta", ["octa"]), ("Auth0", ["auth zero", "auth 0"]),
    ("Stripe", ["stripe"]), ("Plaid", ["plaid"]), ("Twilio", ["twilio", "twillio"]), ("SendGrid", ["send grid"]),
    ("HubSpot", ["hub spot"]), ("Salesforce", ["sales force"]), ("Zendesk", ["zen desk"]), ("Intercom", ["inter com"]),
    ("Shopify", ["shop ify", "shopify"]), ("Webflow", ["web flow"]), ("Tailwind", ["tail wind"]), ("Next.js", ["next js", "next j s"]),
    ("SvelteKit", ["svelte kit", "svelt kit"]), ("Vite", ["veet", "vite"]), ("esbuild", ["e s build", "es build"]),
    ("TypeScript", ["type script"]), ("Kotlin", ["kotlin"]), ("Jetpack Compose", ["jet pack compose"]), ("Flutter", ["flutter"]),
    ("React Native", ["react native"]), ("Firebase", ["fire base"]), ("DynamoDB", ["dynamo d b", "dynamo db"]),
    ("CloudFront", ["cloud front"]), ("Fargate", ["far gate"]), ("SageMaker", ["sage maker"]), ("Vertex AI", ["vertex a i"]),
    ("Home Assistant", ["home assistant"]), ("Zigbee", ["zig bee"]), ("HomeKit", ["home kit"]), ("CarPlay", ["car play"]),
    ("MagSafe", ["mag safe"]), ("Thunderbolt", ["thunder bolt"]), ("USB-C", ["usb c", "u s b c"]), ("NVMe", ["n v m e", "nvme"]),
    ("CUDA", ["cuda", "kuda"]), ("Vulkan", ["vulcan"]), ("Unreal Engine", ["unreal engine"]), ("Blender", ["blender"]),
    ("DaVinci Resolve", ["da vinci resolve", "davinci resolve"]), ("Final Cut Pro", ["final cut pro"]), ("Ableton", ["able ton", "ableton"]),
    ("Lightroom", ["light room"]), ("InDesign", ["in design"]), ("Keynote", ["key note"]), ("SharePoint", ["share point"]),
    ("OneDrive", ["one drive"]), ("Webex", ["web ex"]), ("macOS", ["mac o s", "mac os"]), ("watchOS", ["watch o s", "watch os"]),
    ("visionOS", ["vision o s", "vision os"]), ("ESP32", ["e s p thirty two", "esp 32"]), ("Raspberry Pi", ["raspberry pie"]),
    ("Mixpanel", ["mix panel"]), ("Amplitude", ["amplitude"]), ("LaunchDarkly", ["launch darkly"]), ("Postman", ["post man"]),
    ("Homebrew", ["home brew"]), ("Ollama", ["o llama", "olama"]), ("llama.cpp", ["llama c p p", "llama cpp"]),
    ("Hugging Face", ["hugging face"]), ("Weights & Biases", ["weights and biases"]), ("ClickHouse", ["click house"]),
    ("TimescaleDB", ["timescale d b", "time scale db"]), ("CockroachDB", ["cockroach d b", "cockroach db"]), ("Pulumi", ["pulumi", "pulu me"]),
    ("Backstage", ["back stage"]), ("OpenTelemetry", ["open telemetry"]), ("Jaeger", ["yeager", "jaeger"]), ("Wireshark", ["wire shark"]),
]

# Invented names: built from these parts so they look like product, company and project names.
PREFIX = ["Lumen", "Arbor", "Cinder", "Fern", "Harbor", "Kestrel", "Marrow", "North", "Opal", "Pebble", "Quartz",
          "Ridge", "Sable", "Tidal", "Vesper", "Willow", "Zephyr", "Copper", "Ember", "Granite", "Juniper", "Lark",
          "Moss", "Nimbus", "Orchid", "Prism", "Rune", "Slate", "Thistle", "Umber", "Wren", "Yarrow", "Basalt",
          "Cobalt", "Dune", "Frost", "Glade", "Heron", "Iris", "Jasper", "Kelp", "Linden", "Maple", "Nettle",
          "Onyx", "Plover", "Quince", "Rowan", "Saffron", "Tern", "Velvet", "Wicker", "Alder", "Birch", "Cairn"]
SUFFIX = ["ly", "ify", "wise", "stack", "forge", "loop", "mint", "nest", "path", "port", "scope", "shift", "sync",
          "works", "labs", "base", "cast", "dock", "grid", "hive", "kit", "leaf", "line", "nova", "pad", "pulse",
          "sense", "spark", "trail", "vault", "yard", "ware", "bit", "deck", "field", "gate"]
COMPANY_TAIL = ["Logistics", "Health", "Robotics", "Capital", "Studios", "Systems", "Foods", "Partners", "Biotech",
                "Insurance", "Media", "Freight", "Energy", "Ventures", "Consulting", "Labs", "Collective"]
PROJECT_HEAD = ["Project", "Operation", "Initiative"]

DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
TIMES = ["nine", "ten", "eleven", "noon", "one", "two", "three", "four", "five", "six", "seven", "eight"]
NUMBERS = ["two", "three", "four", "five", "six", "seven", "eight", "ten", "twelve", "fifteen", "twenty"]
MONTHS = ["January", "February", "April", "May", "July", "August", "September", "October", "November", "December"]
PLACES = ["the lobby", "the big conference room", "the cafe downstairs", "the third floor", "the rooftop",
          "the library", "the east wing", "the training room", "the kitchen", "the garage", "room four"]
LANGS = [("Spanish", "es"), ("French", "fr"), ("German", "de"), ("Italian", "it"), ("Portuguese", "pt"),
         ("Japanese", "ja"), ("Chinese", "zh"), ("Korean", "ko"), ("Dutch", "nl")]

# Clean sentences with slots: {P} person, {P2} another person, {T} tool, {C} invented product/company,
# {D} day, {TM} time, {N} number, {M} month, {PL} place, {PRJ} project.
NAMED = [
    "Can you ask {P} to look at the {T} alerts before {D}?",
    "I'll sync with {P} about the {C} contract this afternoon.",
    "{P} said the {T} upgrade broke the nightly build again.",
    "Please loop in {P} and {P2} on the {C} renewal.",
    "We should move the {T} cluster to the new region before {M}.",
    "Tell {P} that the {C} demo is pushed to {D} at {TM}.",
    "Did {P} ever send over the {T} benchmarks?",
    "I'm pairing with {P} on the {T} migration tomorrow morning.",
    "The {C} team wants a walkthrough of our {T} setup.",
    "Let's ask {P} whether {C} supports single sign-on yet.",
    "{P} is out until {D}, so ping {P2} about the {T} config.",
    "Our {T} bill doubled last month, can {P} take a look?",
    "Thanks {P}, I'll forward the {C} invoice to finance.",
    "I need to update the {T} docs before the {C} launch.",
    "{P} and I are presenting the {PRJ} roadmap on {D}.",
    "Can someone restart the {T} workers before {TM}?",
    "The {PRJ} kickoff is with {P} on {D} in {PL}.",
    "I just pushed a fix for the {T} timeout that {P} reported.",
    "{C} is sending two engineers to help with the {T} rollout.",
    "Remind me to email {P} about the {C} pricing on {D}.",
    "We switched from {T} to {T2} for the analytics pipeline.",
    "Is {P} still the owner of the {PRJ} budget?",
    "Ask {P} to share the {C} slides in the channel.",
    "{P} {S} will join the call from {C}.",
    "Please book {PL} for the {PRJ} retro on {D}.",
    "The {C} integration needs a new {T} webhook.",
    "I think {P} already fixed the {T} memory leak.",
    "Our intern {P} built a small {T} plugin for {C}.",
    "Can we get {P} {S} on the {PRJ} steering group?",
    "Send the {T} logs to {P} before the postmortem.",
    "{P} wants to rewrite the onboarding flow in {T}.",
    "The {C} account manager is {P} {S}.",
    "We're hiring a {T} contractor for the {PRJ} work.",
    "Let {P} know the {T} certificate expires on {D}.",
    "{P} from {C} asked for read access to our {T} project.",
    "Could {P} review my pull request for the {T} cache?",
    "The {PRJ} launch slipped because {T} kept crashing.",
    "I'll draft the {C} proposal and send it to {P} tonight.",
    "{P} is giving a lightning talk about {T} on {D}.",
    "Did you see the message from {P} about {C}?",
    "Move the {PRJ} standup to {TM} so {P} can join.",
    "We owe {C} an answer on the {T} licensing question.",
    "Please add {P} {S} to the {C} guest list.",
    "Can you check if {T} works with {T2} out of the box?",
    "{P} said {C} might acquire a small {T} startup.",
    "I'm flying to meet the {C} folks with {P} in {M}.",
    "The {T} dashboard shows errors spiking after {TM}.",
    "Ask {P} to rotate the {T} keys this week.",
    "Our {PRJ} prototype runs entirely on {T}.",
    "Congrats to {P} for shipping the {C} beta!",
    "I'll take notes for {P} during the {C} call.",
    "{P} prefers {T} over {T2} for this kind of job.",
    "The {C} outage was caused by a bad {T} deploy.",
    "Please forward {P}'s comments on the {PRJ} spec.",
    "We need {P} to sign off on the {C} security review.",
    "Grab lunch with {P} and {P2} after the {T} workshop?",
    "My manager {P} approved the {T} training budget.",
    "The new {C} build fixes the {T} sync issue.",
    "Did {P} get the {C} badge for the office yet?",
    "{P} will cover support while I'm at the {T} conference.",
]

# Plain sentences without names (for fillers, corrections, questions and echo tests).
PLAIN = [
    "We need to finish the slides before the client call.",
    "The printer on our floor is jammed again.",
    "I'll pick up the groceries on the way home.",
    "Let's push the release until the tests are green.",
    "The coffee machine in the kitchen is finally fixed.",
    "Can we keep the agenda short this week?",
    "I left my charger in the meeting room.",
    "The new hires start on the first of the month.",
    "Please water the plants while I'm away.",
    "Traffic was terrible so I'll be a few minutes late.",
    "We should celebrate once the launch is done.",
    "The draft looks good but the intro is too long.",
    "I want to try the new ramen place near the station.",
    "Our flight lands just after midnight.",
    "The kids have a dentist appointment tomorrow.",
    "I'm working from home for the rest of the week.",
    "The budget spreadsheet has a broken formula.",
    "Make sure everyone signs the attendance sheet.",
    "I finished the first chapter last night.",
    "We ran out of paper towels in the bathroom.",
    "The heating in the office is way too strong.",
    "I'll send the photos from the trip later today.",
    "Can you grab an extra chair for the visitor?",
    "The parking garage closes at ten tonight.",
    "My laptop battery barely lasts two hours now.",
    "We're out of milk and the cereal is stale.",
    "The rent goes up by fifty dollars next month.",
    "The bus was packed so I walked instead.",
    "Let's take a short break and come back in ten minutes.",
    "I'm not sure the numbers in this report add up.",
    "Our neighbors are having a barbecue on the weekend.",
    "The workshop sold out in less than a day.",
    "I think the font on the poster is too small.",
    "Please lock the back door when you leave.",
    "The garden needs weeding before the party.",
    "I'll be offline during the flight.",
    "The interview went better than I expected.",
    "We should order more stickers for the booth.",
    "The soup needs a little more salt.",
    "Someone left the lights on in the storage room.",
    "Our team dinner is booked for eight people.",
    "The quarterly survey closes at the end of the day.",
    "I'd rather take the train than drive in the snow.",
    "The new chairs are much more comfortable.",
    "Remember to bring your passport to the airport.",
    "The movie starts in twenty minutes.",
    "I can't find the receipt for the hotel.",
    "Let's keep the meeting notes in one shared folder.",
    "The wifi in the hotel lobby is really slow.",
    "We walked to the lake and had a picnic.",
]

# Correction-slot templates: {X} is spoken as "a <cue> b" and written as b.
CORRECTABLE = [
    ("Can we meet on {X} after lunch?", "day"), ("The call is at {X} tomorrow.", "time"),
    ("Book a table for {X} people.", "num"), ("Send the invoice to {X} by Friday.", "person"),
    ("We'll meet in {X} for the review.", "place"), ("I need {X} copies of the handout.", "num"),
    ("The deadline is {X}, not earlier.", "day"), ("Pick me up at {X} tonight.", "time"),
    ("Can you invite {X} to the planning session?", "person"), ("The flight leaves on {X} morning.", "day"),
    ("Order {X} pizzas for the team lunch.", "num"), ("Let's do the demo in {X}.", "place"),
    ("The workshop starts at {X} sharp.", "time"), ("Ask {X} to approve the expense.", "person"),
    ("We're launching in {X}.", "month"), ("Move the dentist appointment to {X}.", "day"),
    ("Reserve {X} for the offsite.", "place"), ("The movie night is on {X}.", "day"),
    ("I'll call you back at {X}.", "time"), ("Our trip is planned for {X}.", "month"),
]
CUES = ["no", "sorry", "I mean", "actually", "actually make it", "wait", "or rather", "no wait", "make that", "sorry I mean"]
# No "so": a sentence-opening So/Well/Okay is kept (the fine-tune prompt names only um, uh, like, basically, you know).
FILLERS = ["um", "uh", "like", "you know", "basically", "I mean"]

# Sentences where a correction or filler word is real content and must stay.
KEEP = [
    "I actually love the updated layout.", "No, I don't think we need another meeting.",
    "Sorry I missed your call earlier.", "I mean it, the new onboarding flow is great.",
    "There's no reason to delay the release.", "It looks like rain this afternoon.",
    "Do you actually need the full report?", "I like the way the team handled the demo.",
    "Sorry for the late reply, I was traveling.", "No problem, I can cover your shift.",
    "We basically agreed on everything except the price.", "Actually, the venue changed to the library.",
    "I'd like two copies of the contract.", "The results were, like, ten times better.",
    "You know the drill, badges at the door.", "I mean, what else could we do?",
    "Wait for my signal before you start.", "That's actually a great idea.",
    "No one replied to the survey yet.", "Feels like we've done this before.",
]

# Questions and requests that must be written down, never answered or carried out.
ASKS = [
    "How do you feel about switching to a four day week?", "Can you write a short poem about autumn?",
    "How many people signed up for the workshop?", "Should we cancel the offsite this year?",
    "Tell me a joke about spreadsheets.", "Summarize the last three emails for me.",
    "What's the capital of Australia?", "Could you translate this into Spanish?",
    "Why does the build take so long?", "Draft a reply saying I'll be there.",
    "Is it going to snow this weekend?", "Who's covering the front desk tomorrow?",
    "Explain how compound interest works.", "Write a thank you note to the caterers.",
    "Which option did the client prefer?", "Can you list the pros and cons of remote work?",
    "Where did we put the spare keys?", "When is the next team offsite?",
    "Give me three ideas for the team name.", "Do we have budget left for a new monitor?",
]

# Short phrases for inserts and replacements.
PHRASES = [
    "let me know if you have questions", "talk soon", "thanks again for your help", "happy to jump on a call",
    "catch you at the offsite", "the link is in the doc", "hope you had a great weekend", "looking forward to it",
    "I'll follow up tomorrow", "no rush on this", "the deadline is end of month", "welcome to the team",
    "please review by Wednesday", "cheers", "best regards", "hi everyone", "quick update", "good morning team",
    "one more thing", "for context", "heads up", "as discussed yesterday", "sorry for the delay",
    "attached are the final numbers", "great work everyone", "this is still a draft", "TL;DR we're on track",
    "feel free to edit", "dinner is on me", "the office is closed on Monday",
]

TITLES = [
    "Weekly Sync Notes", "Draft Proposal", "Untitled", "Budget Planning 2027", "Launch Checklist",
    "Team Offsite Ideas", "Hiring Plan", "Onboarding Guide", "Retro Notes", "Customer Feedback",
    "Design Review", "Holiday Schedule", "Roadmap v2", "Meeting Agenda", "Reading List",
    "Release Notes", "Travel Plans", "Research Summary", "Open Questions", "Action Items",
]

# Lists that become prose ("We need a, b, and c.") and back into bullets.
LISTS = [
    ["book the venue", "order the catering", "send the invitations", "print name tags"],
    ["apples", "spinach", "rice", "coffee beans", "olive oil"],
    ["update the changelog", "tag the release", "notify support"],
    ["passport", "phone charger", "sunscreen", "a rain jacket"],
    ["review the contract", "schedule the kickoff", "set up the shared drive"],
    ["vacuum the living room", "take out the recycling", "fold the laundry"],
    ["fix the login bug", "add dark mode", "improve the search speed", "write more tests"],
    ["call the bank", "renew the car insurance", "book the vet"],
    ["tomatoes", "basil", "mozzarella", "garlic"],
    ["finalize the budget", "hire two designers", "plan the user interviews"],
    ["water the garden", "feed the cat", "collect the mail"],
    ["draft the agenda", "invite the speakers", "test the projector", "order coffee"],
    ["clean the gutters", "replace the smoke alarm batteries", "repaint the fence"],
    ["pasta", "parmesan", "lemons", "frozen peas"],
    ["update the website", "post on social media", "email the newsletter"],
]

# Long, padded sentences and their core meaning (for "make it shorter").
PADDING_OPEN = [
    "I just wanted to quickly reach out and let you all know that", "As some of you may already be aware,",
    "I hope this message finds you well. I'm writing to say that", "Just as a quick heads up for everyone,",
    "I thought it would be a good idea to mention that", "For what it's worth, I wanted to point out that",
    "Following up on our earlier conversation, I wanted to confirm that",
]
PADDING_CLOSE = [
    ", so please plan accordingly and let me know if that causes any problems for you.",
    ", and I really appreciate everyone's patience and flexibility while we sort this out.",
    ", so feel free to reach out to me directly if you have any questions or concerns at all.",
    ". Thanks so much in advance for your understanding, and sorry for any inconvenience this may cause.",
    ", which I think is good news for all of us, all things considered.",
]
CORES = [
    "the workshop has moved to Thursday morning", "the office will be closed next Friday",
    "the new expense policy starts in April", "the client approved the second design",
    "the server maintenance is scheduled for Sunday night", "lunch will be provided at the offsite",
    "the deadline for the grant application is the fifteenth", "the parking lot will be repaved this weekend",
    "the quarterly review has been postponed by a week", "the new laptops arrive on Monday",
    "the team dinner is now at the Italian place", "the training session is fully booked",
]

# Informal messages for tone edits (teacher-labelled). {P} etc. filled like NAMED.
INFORMAL = [
    "yo can u check the {T} thing when u get a sec", "hey quick q, did {P} ever reply abt {C}",
    "gonna be late, traffic is nuts", "pls send me the slides b4 the call thx", "lol the {T} build broke again",
    "cant make it tmrw, sorry!!", "need the numbers asap, boss is asking", "ok cool ill handle the {C} stuff",
    "whats the status on the {PRJ} thing", "can we push the mtg to {D}?", "thx for covering, owe u one",
    "the demo was kinda rough ngl", "u around for a quick call?", "fyi {P} is out sick today",
    "send me the doc when ur done pls", "this {T} bug is driving me nuts",
]
FORMAL = [
    "Dear team, please find attached the minutes from Tuesday's meeting.",
    "I would be grateful if you could review the attached proposal at your earliest convenience.",
    "Kindly ensure that all expense reports are submitted by the end of the month.",
    "We regret to inform you that the event has been cancelled due to unforeseen circumstances.",
    "Please be advised that the {C} office will be closed for maintenance on {D}.",
    "I am writing to request an extension on the {PRJ} deliverable.",
    "Thank you for your patience while we investigate the {T} outage.",
    "Per our discussion, I have updated the timeline for the {PRJ} rollout.",
]

TONES = ["more formal", "more casual", "friendlier", "more polite", "more professional", "more direct",
         "less formal", "more confident", "warmer", "more concise and professional"]

# Filler sentences for long screen contexts: notes, threads and documents.
FILLER = [
    "The sprint demo ran long because the projector would not connect.",
    "Someone suggested we try async updates instead of the Wednesday call.",
    "The office plants were moved closer to the windows over the weekend.",
    "Customer tickets about password resets dropped after the email change.",
    "We agreed to revisit the pricing page copy after the holidays.",
    "The design system now has a dark variant for every component.",
    "Legal asked us to add a cookie banner to the marketing site.",
    "Two people volunteered to organize the summer picnic.",
    "The mobile app review took three days longer than usual.",
    "Sales wants a one-pager they can send to prospects.",
    "Backups are now tested every Sunday at midnight.",
    "The kitchen fridge will be emptied on Friday afternoon.",
    "Support hours are changing for the winter.",
    "The analytics export now includes time zones.",
    "We are still waiting on the final numbers from the venue.",  # was "…final quote from the printer", now a bench case (d-fmt)
    "The internal wiki search is much faster since the upgrade.",
    "Next quarter we want fewer meetings and longer focus blocks.",
    "The visitor badges are in the top drawer at reception.",
    "A few people reported the VPN dropping during calls.",
    "The style guide now prefers sentence case for headings.",
    "Hardware requests should go through the new form.",
    "The beta feedback was mostly positive about speed.",
    "Please label leftovers before putting them in the fridge.",
    "Our newsletter open rate went up after the redesign.",
    "We moved the archive folders to cold storage.",
]

CHANNELS = ["#general", "#design", "#backend", "#ops", "#marketing", "#random", "#launch", "#support", "#data", "#mobile"]
APPS = [("Slack", "{ch}"), ("Mail", "Inbox"), ("Notes", "Meeting notes"), ("Messages", "{p}"), ("Linear", "Issues"),
        ("Notion", "{prj}"), ("Google Docs", "{prj} spec"), ("Calendar", "Week"), ("Safari", "{c} – Dashboard"), ("Xcode", "{c}")]

# Instruction phrasings, by edit kind. None of these is a bench utterance.
SHORTER = ["make this shorter", "shorten this", "make this more concise", "trim this down", "cut this down",
           "can you shorten it", "make it more concise", "tighten this up", "make it brief", "too wordy, shorten it",
           "shorter please", "condense this"]
BULLETS = ["make this a bulleted list", "bullet these", "convert to bullets", "make it a list", "bullet points please",
           "turn this into a list", "format as bullet points", "put these in bullets", "split this into bullet points",
           "list format please"]
NUMBERED = ["make this a numbered list", "number these", "turn this into numbered steps", "put this in a numbered list"]
TYPO = ["fix the typos", "fix the spelling", "correct the spelling mistakes", "fix typos", "there's a typo, fix it",
        "fix the spelling errors"]
GRAMMAR = ["fix grammar", "correct the grammar", "can you fix the grammar here", "grammar fix please",
           "make this grammatically correct", "fix the grammar in this"]
INSERT_AFTER = ["add after this: {x}", "after this add {x}", "append {x}", "put {x} at the end", "add {x} after it",
                "then add {x}", "add a line after: {x}", "add at the end: {x}"]
INSERT_BEFORE = ["add before this: {x}", "put {x} at the start", "add {x} at the top", "prepend {x}", "add {x} before it",
                 "insert {x} at the beginning", "add at the start: {x}"]
CASE = [("make this title case", "title"), ("all caps", "upper"), ("make it uppercase", "upper"),
        ("lowercase this", "lower"), ("make it all lowercase", "lower"), ("capitalize every word", "title")]
SPELL_INTRO = ["it's {n}, {s}", "that's {n}, {s}", "should be {n}, {s}", "spell it {s}", "it's spelled {s}",
               "the name is {n}, {s}", "wrong spelling, it's {s}", "{n}, {s}"]
CONTEXT_FIX = {"person": ["fix the name", "fix her name", "fix his name", "spell their name right", "correct the name",
                          "use the right spelling for the name", "fix the spelling of the name"],
               "company": ["fix the company name", "fix the client name", "correct the vendor name", "fix the partner's name",
                           "spell the customer name right", "the company name is wrong"],
               "product": ["fix the product name", "correct the tool name", "fix the spelling of the app",
                           "spell it like on screen", "use the right product name"],
               "project": ["fix the project name", "correct the codename", "spell the project name right"]}
REMEMBER = [", and remember this", ", remember that", ", please remember it", ", save that spelling"]

# ---------- v3 (#60): new families only; the lists above stay as they were so old streams don't shift ----------

# Long screens where multi-sentence dictations got condensed (#47): chat threads, terminals, email.
CHAT_LINES = [
    "can someone look at the failing nightly job?", "pushed a small fix, should be green in ten minutes",
    "is the staging database still read only?", "thanks, that worked for me", "I'll be out tomorrow afternoon",
    "the vendor call moved to Thursday", "who has the spare dongle for the projector?", "lgtm, merging after lunch",
    "heads up, the office wifi is flaky today", "anyone else getting logged out every hour?",
    "the design review notes are in the doc", "can we skip standup today?", "I'm rerunning the export now",
    "that sounds like a cache issue to me", "ok, I'll open a ticket", "the build agent ran out of disk again",
]
TERMINAL_LINES = [
    "$ git status", "On branch main", "Your branch is up to date with 'origin/main'.", "nothing to commit, working tree clean",
    "$ make test", "ok   ./internal/store   0.412s", "FAIL ./internal/api   1.093s", "--- FAIL: TestRetryBackoff (0.21s)",
    "$ docker compose up -d", "Container cache-1  Started", "Container worker-1  Restarting", "$ tail -f logs/worker.log",
    "WARN connection reset by peer, retrying", "ERROR job 4821 exceeded its deadline", "$ npm run build",
    "Compiled with 3 warnings.", "$ df -h /", "/dev/disk3s1   460Gi   441Gi    19Gi    96%    /",
]
MAIL_LINES = [
    "Hi all,", "Thanks for joining the planning session yesterday.", "Attached are the slides and the rough timeline.",
    "Please send any corrections by the end of the week.", "Best,", "The venue can host up to forty people.",
    "Nobody has signed up for the catering order yet.", "Let me know if anything in the timeline looks off.",
    "On Monday, the facilities team wrote:", "> The east entrance will be closed for repairs.", "Kind regards,",
]
MULTI_STATEMENTS = [
    "The deploy finished but the health check is still red.", "I reran the migration on a copy of the database.",
    "The flaky test only fails when the cache is cold.", "I bumped the timeout to thirty seconds for now.",
    "The logs show the worker restarting every few minutes.", "Half of the requests are hitting the old endpoint.",
    "I rolled back the config change from this morning.", "The disk on the build machine is almost full.",
    "I opened a ticket with the vendor about the outage.", "The new branch builds cleanly on my machine.",
    "Nothing changed in the lockfile since Friday.", "The script works locally but not in the container.",
    "Thanks for the detailed notes from yesterday.", "I moved the planning doc into the shared folder.",
    "The venue confirmed the booking for the second week.", "Most of the team voted for the earlier slot.",
    "The caterer needs the final headcount soon.", "I'm going to be about fifteen minutes late.",
    "The demo went fine apart from the login screen.", "We lost about an hour to the network issue.",
]
MULTI_REQUESTS = [
    "Can you rerun the pipeline when you get a minute?", "Could you send me the error message you saw?",
    "Can someone with admin access restart the runner?", "Would you mind checking the worker logs?",
    "Can you tell me which version you're on?", "Could you paste the full stack trace here?",
    "Do you know who owns the billing service?", "Should I open a separate issue for this?",
    "Is anyone else seeing the same timeout?", "Can we pair on this after the standup?",
    "Could you approve the pull request when it's green?", "Who should I ask about the expired certificate?",
    "Could you confirm the headcount by Thursday?", "Let me know if the new time works for you.",
    "Can you share the slides with the wider group?", "What do you think we should do about the delay?",
]

# Spans the pre-pass (Pipeline.spokenFormatting) turns into marks (#48), and templates that hold them.
QUOTED = ["out of office", "ship it", "works on my machine", "low priority", "needs review", "coming soon",
          "do not merge", "sounds good", "temporarily unavailable", "on hold", "ready for QA", "won't fix"]
QUOTE_T = ["The ticket title says “{q}” but the bug is somewhere else.", "She replied with just “{q}” and logged off.",
           "The button label should read “{q}” instead.", "Set the status to “{q}” until we hear back.",
           "The banner on the homepage still says “{q}” for some reason.", "His whole review was “{q}” and a thumbs up."]
PAREN = ["still pending", "not final", "approved last week", "roughly", "subject to change", "first draft",
         "including taxes", "see the appendix", "if the weather holds", "two at most"]
PAREN_T = ["The launch date ({p}) depends on the security review.", "Our budget ({p}) covers two more contractors.",
           "The offsite ({p}) is at the lake house.", "The new pricing ({p}) goes live next month.",
           "The headcount ({p}) is twelve people.", "Bring a laptop and a charger ({p}) to the session."]
GREETINGS = ["Hi {P}.", "Hello everyone.", "Morning {P}.", "Hey team.", "Dear {P},"]
SIGNOFFS = ["Thanks,", "Cheers,", "Best,", "See you soon,"]

# Spoken lists while dictating (#48).
LIST_LEADS = ["shopping list", "packing list", "weekend jobs", "agenda for tomorrow", "before the launch",
              "errands", "steps for the release", "for the trip", "chores", "for the party"]
ORDINALS = ["first", "second", "third", "fourth", "fifth"]

# Emails, URLs and handles (#48).
TLDS = ["com", "io", "org", "dev", "app", "co"]
URL_PATHS = ["pricing", "docs", "setup", "careers", "status", "signup", "blog", "changelog", "support", "events"]
EMAIL_T = ["Send the contract to {e}.", "My work email is {e}.", "You can reach the vendor at {e}.",
           "Please cc {e} on the thread.", "The invoice came from {e}.", "Forward the receipts to {e}."]
URL_T = ["The docs are at {u}.", "Sign up at {u} before Friday.", "I put the notes on {u}.",
         "Check {u} for the new pricing.", "The status page is {u}.", "Bookmark {u} for later."]
HANDLE_T = ["Ping {h} on the thread.", "Follow {h} for release updates.", "Tag {h} in the post.",
            "The account to mention is {h}.", "Send a DM to {h} about the meetup."]

# Spelling while dictating and spelled corrections (#48, #50). Names whose spoken form comes out as
# letters: (written, sound-alike letters, misheard selections). "Ajay" (the #50 report) is a bench case.
LETTER_NAMES = [("Casey", "K C", ["kc", "k c"]), ("Evie", "E V", ["eevee", "e v"]), ("Ellie", "L E", ["elly", "l e"]),
                ("Artie", "R T", ["arty", "r t"]), ("Emmy", "M E", ["emmie", "m e"]), ("Katie", "K T", ["kt", "katy"]),
                ("Jaycee", "J C", ["jc", "j c"]), ("Essie", "S E", ["essy", "s e"]), ("Eddie", "E D", ["eddy", "e d"]),
                ("Ivy", "I V", ["i v", "ivey"]), ("Effie", "F E", ["effy", "f e"]), ("Deejay", "D J", ["dj", "d j"]),
                ("Elsie", "L C", ["elsy", "l c"]), ("Bea", "B", ["b", "bee"]), ("Kay", "K", ["k", "kaye"])]
SPELL_DICT_T = ["Please send the file to {x}.", "I'm meeting {x} for coffee on {D}.", "Add {x} to the guest list.",
                "The new contractor is called {x}.", "Can you book a room for {x} and me?", "Say hi to {x} from me.",
                "The keynote is by {x} this year."]
SPELL_EDIT_T = ["{x}", "it's {x}", "no, {x}", "that's {x}", "should be {x}", "the name is {x}", "wrong, it's {x}"]

# Context name fixes whose right form joins words (#45 regression: "pg vector" → "pgvector" came out "vector").
JOIN_PREFIX = ["pg", "kv", "js", "tf", "np", "ts", "ml", "db", "gh", "rx", "mx", "zk"]
JOIN_SUFFIX = ["bouncer", "store", "lint", "bench", "search", "graph", "queue", "proxy", "watch", "cron", "sync",
               "embed", "admin", "dump", "shard"]
JOIN_FIX = ["it's one word, like on screen", "spell it the way the screen does", "wrong name, check the screen",
            "fix this tool name", "that's the library on screen", "use the name from the screen", "should match the screen",
            "the package name is wrong", "write it as one word"]

# Bare phrases over a selection: replace, not insert (#44), and misheard "Replaced this with X" (#53).
SHORT_TERMS = ["grace period", "retry budget", "cooldown window", "rate limit", "warm-up phase", "sync interval",
               "fallback model", "draft mode", "quiet hours", "review queue", "launch window", "error budget",
               "batch size", "cache lifetime", "idle timeout", "release train", "feature flag", "soft deadline",
               "hard cap", "trial period", "focus mode", "follow-up date", "approval step", "beta group",
               "Afternoon tea", "Sunday brunch", "Kickoff call", "Field notes", "Parking lot", "Open floor"]
REPLACE_VERBS = ["Replaced", "Replace", "Replacing", "Swap", "Swapped", "Replaced", "Replaced"]
REPLACE_OBJ = ["this", "that", "it", "the selection", ""]

# Spoken numbers the ITN pass (Pipeline.spokenNumbers, #59) turns into digits. Targets are written in words
# here; PoptalkDatagen render runs the same pass on dictation targets, so both sides carry the same digits.
COMPOUND = ["twenty five", "thirty two", "forty eight", "sixty one", "ninety nine", "seventy four", "eighteen",
            "fifty six", "eighty three", "one hundred and twenty", "two hundred", "fifteen hundred", "three thousand",
            "two hundred and forty", "thirty", "forty", "sixty", "eleven", "thirteen", "nineteen"]
SMALL = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
ORD_COMPOUND = ["twenty first", "twenty third", "twenty fifth", "twenty eighth", "thirty first", "twenty fourth"]
CLOCK = ["three thirty", "four fifteen", "eleven oh five", "nine", "ten forty five", "two", "seven twenty", "six"]
NUM_T = ["{CN} people signed up for the workshop.", "The fix is in issue {U}.", "Let's ship version {U} on {D}.",
         "Step {U} is the slow one.", "Page {U} has the chart you asked about.", "Sign-ups are up {CN} percent this week.",
         "The license costs {CN} dollars a seat.", "The call moved to {CL} {AP}.", "The deadline is the {ORD} of {M}.",
         "We need {CN} more chairs for the hall.", "The build takes {CN} minutes now.", "The rating went up to {U} point {U2}.",
         "The lease ends in {M} two thousand twenty seven.", "Two of us can cover it, maybe three.",
         "One or two reviewers is enough for this.", "We waited {CN} minutes for the shuttle.",
         "Room {U} is free after lunch.", "Option {U} is the cheapest one.", "Our team grew to {CN} people this year.",
         "The order is {CN} dollars with shipping.", "About {CN} percent of the tickets are duplicates.",
         "Can you move the review to {CL} {AP} on {D}?", "I read {SM} chapters on the train.",
         "The package weighs {U} point {U2} kilos."]

# ---------- v4: history-driven families (only counts were read from history; all text below is invented) ----------
# Most real dictations go to a coding agent in a terminal: long agent screens full of bullets, tool calls and code
# identifiers, with short replies at its prompt. v3 sometimes bulletized a one-sentence to-do there.
AGENT_LINES = [
    "⏺ Read(src/settings/store.ts)", "  ⎿  Read 188 lines", "⏺ Bash(npm test)", "  ⎿  41 passed, 2 failed",
    "⏺ Update(src/net/client.ts)", "  ⎿  Updated with 6 additions and 3 removals", "✻ Thinking…",
    "⏺ The failing case expects the counter to reset after a success.", "⏺ Here's what I changed:",
    "  - Moved the timeout into the shared settings", "  - Added a guard for empty responses",
    "  - Kept the old behaviour behind a flag", "  - Removed the duplicate import", "⏺ Search(pattern: \"timeout\")",
    "  ⎿  Found 9 files", "+    if (!body) return null;", "-    return body.items;", "  ⎿  Interrupted by user",
    "⏺ Done. The build is green again.", "Do you want me to commit these changes?", "  1. Yes", "  2. No, keep editing",
    "⏺ Next steps:", "  - Run the full suite in CI", "  - Update the changelog", "⏺ Bash(make lint)",
    "  ⎿   3 files changed, 27 insertions(+), 9 deletions(-)", "warning: unused variable `retries`",
    "error[E0308]: mismatched types", "⏺ I couldn't reproduce the crash locally.", "  ⎿  No matches found",
    "? for shortcuts", "esc to interrupt", "⏺ Write(tests/fixtures/empty.json)", "  ⎿  Wrote 1 line",
]
AGENT_APPS = [("Ghostty", "~/src/{w}"), ("Terminal", "zsh — {w}"), ("iTerm2", "{w} (node)"), ("Ghostty", "{w} — agent")]
REPO_WORDS = ["atlas", "harbor", "ledger", "orbit", "pantry", "relay", "sprout", "tally", "vista", "wharf"]
# What people say to a coding agent, in clean form; the transcript is derived from it.
AGENT_SHORT = ["Yes.", "Yes, go ahead.", "Go ahead.", "Continue.", "Keep going.", "Sounds good, do it.", "Not yet.",
               "Good catch.", "Nope.", "Yep, ship it.", "Great, thanks.", "Stop.", "Try again.", "Do it.", "Perfect.",
               "Hold on.", "That works.", "Leave it."]
AGENT_SAID = [
    "Go ahead and commit that.", "Stop, that's the wrong file.", "No, revert that last change.", "Run the tests again.",
    "Try that again with the verbose flag.", "Looks good, push it.", "Can you explain why that test fails?",
    "Undo the change to the settings file.", "Let's leave the docs for later.", "Wait for the build to finish first.",
    "What does the error message say?", "Show me the diff before you commit.", "Split that into two commits.",
    "Add a comment explaining the workaround.", "Use the existing helper instead of writing a new one.",
    "Don't touch the migration files.", "That's fine for now, we can clean it up later.", "Skip that step.",
    "Open a pull request when it's done.", "Check the logs from the last run.", "Is that change safe to ship today?",
    "Why did you remove the check?", "Put it back the way it was.", "Make the error message more specific.",
    "Can you make that smaller?", "Do the same for the other handlers.", "Bump the version and tag it.",
    "Rebase on main before you push.", "Then update the changelog.", "I don't think that's the root cause.",
    "Let's try the simpler fix and see if the test passes.", "Keep the public API the same.",
    "Read the whole file before you change it.", "The flaky test is unrelated, ignore it.",
    "Can you find where that value gets set?", "Pull the latest changes and build again.",
    "That broke the other screen, look at it again.", "Write the plan down before you start.",
]
# Identifier words: the screen shows them joined (loadConfig, load_config, LoadConfig); speech splits them.
ID_HEAD = ["load", "parse", "fetch", "retry", "flush", "build", "render", "sync", "resolve", "merge", "index", "queue"]
ID_TAIL = ["config", "session", "token", "batch", "upload", "request", "cache", "layout", "budget", "header", "payload"]
IDENT_T = ["Can you rename {I} to something clearer?", "The bug is in {I}, not in the caller.",
           "Add a test for {I} that covers the empty case.", "Why does {I} get called twice?", "Move {I} into its own file.",
           "I think {I} should return early when the list is empty.", "Inline {I} and delete the wrapper.",
           "Check whether {I} handles a missing value.", "Log the arguments that reach {I}.", "Let's make {I} async.",
           "Don't change the signature of {I}.", "Where else do we use {I}?", "Go back to the old version of {I}.",
           "Put a short doc comment on {I}."]
IDENT_LINES = ["⏺ I'll update {I} so it handles the empty case.", "  ⎿  {I} is called from three places",
               "function {I}(options) {{", "def {I}(self):", "error: {I} returned nil", "⏺ Read the body of {I}.",
               "    at {I} (src/core/worker.ts)", "  - {I} now logs its input"]
# To-do-like sentences said without "bullet" or "first … second": they stay prose, never a list.
DEV_TODOS = [["add the missing test", "fix the lint warning", "update the readme"],
             ["bump the dependency", "rerun the benchmarks", "write up the results"],
             ["revert the config change", "clear the cache", "restart the worker"],
             ["delete the unused flag", "rename the helper", "squash the commits"],
             ["check the logs", "find the slow query", "add an index for it"]]
VERB_PROSE = ["I still need to {L}.", "Can you {L}?", "Remember to {L} before Friday.", "Today I want to {L}.",
              "Let's {L} this week.", "Before the demo we should {L}.", "{L}.", "{L}.", "Please {L}."]
NOUN_PROSE = ["We're out of {L}.", "Grab {L} on the way home.", "I packed {L}.", "Can you pick up {L}?"]
NOTE_BULLETS = ["- call the landlord", "- send the deck", "- book flights", "- renew the domain", "- ask about parking",
                "- order a new charger", "- sort the receipts"]
# Sentence-opening So/Well/Okay are kept as said.
KEEP_OPENERS = ["So I think we should wait for the review.", "Well, the second draft reads better.",
                "Okay, let's move the call to the afternoon.", "So the plan is to ship on Friday.",
                "Well, nobody objected in the meeting.", "Okay so the build is green now.",
                "So what do we tell the client?", "Well, that took longer than expected.",
                "Okay, I'll send the invite after lunch.", "So we're keeping the old logo after all.",
                "Well, it works on the staging server.", "Okay, run it one more time."]

# ---------- v5: short lowercase imperatives (every model left some uncapitalized) ----------
# Clean commands without the capital or full stop; gen.py adds those. {P} person, {D} day, {M} month.
IMPERATIVES = [
    "call the bank", "fix the header", "book the vet", "open the spreadsheet", "delete the old drafts",
    "run the backup tonight", "check the oven timer", "update the shared calendar", "move the boxes to the garage",
    "send the slides to {P}", "add milk and eggs to the shopping list", "remind me to water the plants tomorrow",
    "book a table for {D} night", "check the mailbox before you leave", "call {P} back after lunch",
    "move the standup to {D} morning", "update the address on the order form", "delete the duplicate contacts",
    "run the cleanup script on the staging box", "open a ticket for the broken projector",
    "fix the typo in the second paragraph", "send {P} the signed lease by {D}", "add {P} to the planning thread",
    "remind {P} about the dentist on {D}", "book the flights for {M} before prices go up",
    "check whether the hotel includes breakfast", "update the team page with the new photos",
    "delete the branch once it's merged", "run the export again with the new filters",
    "open the window in the meeting room", "fix the wobbly leg on the kitchen table",
    "send the meeting notes to everyone who missed it", "add a reminder for the car service in {M}",
    "move my one on one with {P} to {D}", "check the budget before we order anything else",
    "call the landlord about the leaking tap", "update the readme with the new install steps",
    "cancel the gym membership", "archive the old project folders", "forward the receipt to {P}",
    "rename the file to final version", "share the album with {P} and {P2}", "print two copies of the agenda",
    "turn off the lights in the hallway", "reply to {P} and say I'll be there", "tell {P} I'm running late",
    "order more printer paper", "clean up the downloads folder", "restart the router", "close the pull request",
    "pick up the dry cleaning on {D}", "schedule the review for early {M}", "ask {P} for the updated numbers",
    "grab a coffee for me on your way in", "merge the docs branch after the review",
    "set a timer for twenty minutes", "invite {P} to the kickoff on {D}", "lock the front door",
    "email the venue about parking", "write the release notes before {D}", "review the draft and leave comments",
    "push the fix and let me know", "return the library books by {D}", "pay the water bill",
    "save the form before you close it", "buy a birthday card for {P}", "start the dishwasher",
    "text {P} the address", "post the photos in the group chat", "check in for the flight",
]
# Short commands joined in one breath: split into sentences in the target.
RUNON_JOIN = [" ", " and then ", " then ", " and also ", " also "]
IMPERATIVE_LEADS = ["please", "just", "go ahead and", "remember to", "don't forget to", "make sure to", "quickly",
                    "okay,"]

# ---------- v6: self-corrections beyond "A no B" (#98) ----------
# A later sentence fixes a value said earlier. Written as Parakeet punctuates it; gen.py lowercases most.
LATER_CUES = ["Sorry, I meant", "Oh, I meant", "I meant", "Wait, it's", "Sorry, it's", "Actually, it's",
              "Oh, sorry, I meant", "Actually, make that", "No wait, it's", "Correction, it's"]
# Said between the value and its fix; kept. No days, times, numbers, months, places or names.
BETWEEN = ["Bring your laptop.", "I'll send the link later.", "Let me know if that works.", "Don't forget your badge.",
           "Can you tell the others?", "I'll book the room.", "Wear something warm.", "I'll bring snacks.",
           "Reply when you can.", "Check the shared folder first.", "Thanks for organizing this.",
           "The address is in the invite."]
# (cancelled, kept): a cancellation cue drops the first, the rest of the utterance stays.
CANCELS = [
    ("Let's order pizza for everyone.", "Let's get sandwiches from the deli."),
    ("Tell the client we can start next week.", "Tell them we need another week to plan."),
    ("I'll drive us to the concert.", "Let's take a taxi so nobody has to park."),
    ("Put the meeting notes in the wiki.", "Email them to the whole group."),
    ("We should repair the fence this weekend.", "Let's wait until the weather is warmer."),
    ("Add a section about pricing.", "Keep the pricing out of this draft."),
    ("I'm bringing a salad to the potluck.", "I'll bring dessert."),
    ("Let's move the sofa next to the window.", "Leave it where it is for now."),
    ("Book the early train on the way back.", "Book the late one so we can stay for dinner."),
    ("The report goes out tonight.", "It goes out first thing tomorrow."),
    ("Use the blue template for the slides.", "Use the one with the company colors."),
    ("Let's invite the whole floor.", "Keep it to our team."),
    ("I'll water the garden before I leave.", "The neighbor is doing it this time."),
    ("Let's buy a new kettle.", "The old one just needs descaling."),
    ("Send the photos as attachments.", "Share the album link."),
    ("We can meet at the cafe by the station.", "Let's just do a video call."),
    ("Cancel the newspaper delivery.", "Pause it while we're away."),
    ("Print the tickets at home.", "They're already on my phone."),
    ("Let's hire a cleaner for the move.", "We can do it ourselves."),
    ("Put the spare chairs in the hallway.", "Stack them in the storage room."),
    ("The kids can have pasta tonight.", "Heat up the soup from yesterday."),
    ("Turn the heating up a bit.", "Open a window for some air."),
    ("I'll take the early shift on the weekend.", "I can only do the afternoon."),
    ("Let's split the bill evenly.", "Everyone pays for their own order."),
]
CANCEL_CUES = ["Scratch that.", "Never mind.", "Never mind that.", "Forget that.", "Forget it.", "Actually, scratch that.",
               "No, forget that.", "Actually, never mind.", "Wait, scratch that.", "Never mind, forget it."]
# "‹A› no ‹B› instead": B replaces A, never "not A". (template, slot kind, preposition a speaker repeats or None)
INSTEAD_T = [
    ("Forward the contract to {X}.", "person", "to"), ("Assign the ticket to {X}.", "person", "to"),
    ("Hand the keys to {X} after the viewing.", "person", "to"), ("Seat {X} next to the window.", "person", None),
    ("Ship the samples on {X}.", "day", "on"), ("Move the team photo to {X}.", "day", "to"),
    ("Set the reminder for {X}.", "time", "for"), ("The bus picks us up at {X}.", "time", "at"),
    ("Drop the parcel off at {X}.", "place", None), ("Let's start the renovation in {X}.", "month", "in"),
    # A list instead of a kind: the (A, B) pairs that fit that template.
    ("Let's rent {X} for the move.", [("the small van", "the big one"), ("a trailer", "a truck")], None),
    ("I'll wear {X} to the wedding.", [("the gray suit", "the navy one"), ("the red dress", "the green one")], None),
    ("Book {X} for the trip home.", [("the morning flight", "the evening one"), ("the window seat", "the aisle seat")], None),
    ("Let's stay at {X} on the last night.", [("the cheap hotel", "the one by the beach")], "at"),
    ("We'll print the flyers on {X}.", [("the matte paper", "the glossy paper"), ("thin card", "thick card")], "on"),
]
# Look-alikes: the cue words are content here and stay.
KEEP_CUES = [
    "Don't forget that the office closes early on Friday.", "I meant to call you yesterday but the day got away from me.",
    "Never mind the mess, the movers come tomorrow.", "We chose the ferry instead of the bridge.",
    "Wait until everyone has a seat.", "I always forget the code for the gate.",
    "The cat likes to scratch the new sofa.", "That's not what I meant at all.",
    "I thought the trip would be boring. Actually, it was the best week of the year.", "Make that call before lunch.",
    "Never mind what the forecast says, we're going hiking.", "I'd rather walk than wait for the shuttle.",
    "Wait, is the store open on Sunday?", "Let's play it by ear instead of planning every hour.",
    "Sorry, it took me so long to answer.",
]

# ---------- v7: ASR-style mutations (#103) ----------
# Fillers as Parakeet writes them: real dictations carry mostly "uh" and "um" (pool_profile.py), rarely the rest.
# No "I mean": it is also a self-correction cue.
ASR_FILLERS = [("uh", 55), ("um", 35), ("like", 7), ("you know", 3)]
# Short words a speaker repeats while thinking ("I, I think", "the the").
STUTTER_WORDS = {"i", "the", "we", "it", "it's", "to", "a", "and", "that", "this", "my", "our", "you", "i'll", "we're",
                 "is", "of", "in", "for", "can", "so", "if"}
# Abandoned openings before the real sentence ("we should, let's just go"); no cue words, no complete clause.
FALSE_STARTS = ["we should", "I was going to", "can we", "so the", "I think we", "let's", "maybe we", "do you",
                "I need to", "is it", "could you", "I want to", "so we", "did you", "we need", "I'll", "the thing is",
                "what if we", "I was", "are we"]
# Sound-alike pairs (right, heard) a recognizer swaps where the sentence alone decides, so the target has the right
# word. Generic English; no cue words (no/know and wait/weight stay out).
HOMOPHONES = [("their", "there"), ("there", "their"), ("they're", "their"), ("your", "you're"), ("you're", "your"),
              ("whether", "weather"), ("weather", "whether"), ("accept", "except"), ("except", "accept"),
              ("role", "roll"), ("roll", "role"), ("affect", "effect"), ("effect", "affect"), ("than", "then"),
              ("then", "than"), ("lose", "loose"), ("break", "brake"), ("site", "sight"), ("write", "right"),
              ("here", "hear"), ("hear", "here"), ("knew", "new"), ("week", "weak"), ("buy", "by"), ("whole", "hole"),
              ("piece", "peace"), ("through", "threw"), ("board", "bored"), ("plane", "plain"), ("principal", "principle"),
              ("too", "to"), ("whose", "who's"), ("who's", "whose"), ("aloud", "allowed"), ("suite", "sweet"),
              ("meet", "meat"), ("sent", "cent"), ("waste", "waist"), ("mail", "male"), ("pair", "pear"),
              ("sale", "sail"), ("cell", "sell"), ("steal", "steel")]
# Short-word swaps that leave a fine sentence (a → the, can → could; not the → a, which breaks "the keys"): nothing tells the model, so the target keeps
# the heard word.
FUNCTION_SWAPS = [("a", "the"), ("this", "that"), ("these", "those"), ("those", "these"),
                  ("can", "could"), ("could", "can"), ("will", "would"), ("our", "the"), ("my", "the")]
# Invented brand-like terms that split, merge or blur into ordinary words as Parakeet hears them, like a to-do app
# heard as "to do list" or an audio library as "fluid audio": (written, heard forms). Swapped in for an invented
# entity the dictation already names, so screen and target change with it.
SOUNDALIKE_TERMS = [
    ("Tudalist", ["to do list", "to-do list"]), ("Lucidvoice", ["lucid voice"]), ("Notewise", ["note wise", "know twice"]),
    ("Shiploop", ["ship loop"]), ("Inkwell Labs", ["ink well labs", "inkwell lab"]), ("Bytewise", ["bite wise", "by twice"]),
    ("Taskrail", ["task rail", "tasks rail"]), ("Docuflow", ["docu flow", "doc you flow"]), ("Mailpine", ["mail pine"]),
    ("Querylane", ["query lane", "queer lane"]), ("Saltbox", ["salt box", "salt books"]), ("Kanbanly", ["can ban lee", "kanban lee"]),
    ("Pantrify", ["pantry fy", "pan tree fly"]), ("Syncwell", ["sink well", "sync well"]), ("Loomly AI", ["loom lee a i", "loomly ai"]),
    ("Fernkit", ["fern kit", "fern kid"]), ("Gridops", ["grid ops", "grid opps"]), ("Heyform", ["hey form", "hay form"]),
    ("Pipewise", ["pipe wise"]), ("Cobaltdesk", ["cobalt desk"]), ("Waveline Audio", ["wave line audio", "waveline audio"]),
    ("StackNest", ["stack nest", "stack next"]), ("Railyard", ["rail yard", "real yard"]), ("Tallyhop", ["tally hop", "tally hope"]),
    ("Zentrio", ["zen trio", "sentrio"]), ("Brightloom", ["bright loom"]), ("Codeharbor", ["code harbor"]),
    ("Pixel Forge", ["pixelforge", "pixel for"]), ("Nimbus CI", ["nimbusci", "nimbus c i"]),
]

# ---------- v8: profile-matched pool (#103) ----------
# Invented text, shaped by counts only (pool_profile.py): real dictations are mostly short replies to a coding agent,
# punctuated and cased by Parakeet, over long screens. No cue words ("no", "sorry", "actually", "rather", "I mean").
# 1–5 words: replies, sign-offs and commands. The cleaned text is the whole output.
V8_SHORT = [
    "Sounds good.", "On my way.", "Thanks!", "Thank you.", "Got it.", "Will do.", "Okay, perfect.", "See you soon.",
    "Running late.", "Be there in five.", "Love it.", "Makes sense.", "Fair enough.", "Agreed.", "Works for me.",
    "Not today.", "Maybe later.", "Let's do it.", "All good.", "Nice work.", "Congrats!", "Happy birthday!",
    "Good morning.", "Good night.", "Talk soon.", "Call me.", "Check your email.", "Just landed.", "Almost done.",
    "Coming now.", "Merge it.", "Commit and push.", "Run the tests.", "Revert it.", "Undo that.", "Rename it.",
    "Fix the typo.", "Open the file.", "Try the other approach.", "Use option two.", "Option one.", "The second one.",
    "Both, please.", "Skip it.", "Push it.", "Wait.", "Hmm, interesting.", "Next.", "Continue, please.", "Go on.",
    "Done.", "Lunch?", "Coffee later?", "Happy Friday!", "Thanks, that helps.", "Perfect, thanks.", "Not sure yet.",
    "I'll check.", "Let me think.", "Back in ten.", "Yes, that's right.", "Exactly.", "Good point.", "Same here.",
    "Me too.", "Okay, do that.", "Looks right.", "Ship it today.", "Keep it.", "Delete it.", "Add a test.",
    "Leave it as is.", "That's better.", "Much cleaner.", "Yep.", "Sure.", "Okay.", "Yeah, go for it.",
]
# 1–5 words addressed to "you": short questions and requests the model must leave unanswered.
V8_SHORT_ASK = [
    "Why?", "What happened?", "Why did it fail?", "What changed?", "Is it done?", "Any updates?",
    "How long will it take?", "What do you think?", "Which one is faster?", "Can you explain?", "Can you check?",
    "Can you fix it?", "Does that work?", "Are you sure?", "Where's the config?", "What time is it?",
    "Who wrote this?", "Is the build green?", "Did the tests pass?", "Explain that.", "Tell me more.",
    "Summarize it.", "Show me the diff.", "What's next?", "Any ideas?", "Why is it slow?", "What's wrong?",
    "Translate it.", "Write it for me.", "Answer that.",
]
V8_SHORT_NAMED = ["Thanks, {P}!", "Ask {P}.", "Ping {P} about it.", "Call {P} back.", "Tell {P} I said hi.",
                  "Loop in {P}.", "Assign it to {P}.", "Hi {P}!", "Switch to {T}.", "Is {T} down?", "Restart {T}.",
                  "Ask {P} first.", "Use {T} here."]
# Said to a coding agent, one sentence each.
V8_DEV = [
    "Let's start with the failing test and work backwards.", "The login page still flashes white before the theme loads.",
    "Move the retry logic into its own function.", "Keep the old endpoint working until the clients migrate.",
    "The second approach looks cleaner, go with that one.", "Add a log line when the cache misses.",
    "Make the button disabled while the request is in flight.", "That fixed the crash but now the list doesn't scroll.",
    "Use the same date format as the export screen.", "Delete the unused helpers while you're in there.",
    "The error only shows up on the second launch.", "Write a short note in the readme about the new flag.",
    "Leave the generated files alone.", "Run the linter before you commit.",
    "I'd like the settings page to remember the last tab.", "Pin the dependency to the version we had last week.",
    "The spinner never stops when the upload fails.", "Check whether the migration is safe to run twice.",
    "Add the new field to the response but keep it optional.", "Rename the variable to something that says what it holds.",
    "The fix looks right, but the test name is misleading.", "Make the timeout configurable, don't hard code it.",
    "Don't add a new dependency for this.", "Combine those two commits into one.",
    "Start the dev server and open the dashboard.", "The empty state needs a friendlier message.",
    "Mock the network layer in that test.", "Look at how the other screens handle loading.",
    "This should only run once per session.", "Revert the formatting changes, they make the diff noisy.",
    "The query is slow because it scans the whole table.", "Add an index on the created date column.",
    "Let's ship this behind a feature flag.", "Update the snapshot tests after the layout change.",
    "The dark mode colors are too low contrast.", "Cache the result for five minutes.",
    "Make sure the error reaches the user, not just the log.", "Clean up the temporary files after the job finishes.",
    "We need the same validation on the server side.", "Print the request body so I can see what's sent.",
    "The menu closes before the click registers.", "Group the settings by section like the design shows.",
    "The build is fine now, thanks.", "That's the right file this time.",
    "Hold off on the refactor until the release is out.", "Add a retry with a short backoff.",
    "The upload works on wifi but times out on cellular.", "Bring back the confirmation dialog for deletes.",
    "Keep the function small and give it one job.", "Move the constants to the top of the file.",
    "The test passes alone but fails with the rest of the suite.", "Sort the results by most recent first.",
    "Let's call it a day and pick this up tomorrow.", "Write the migration so it can be rolled back.",
    "Squash the fixup commits before you open the pull request.", "The logs are too noisy, drop the debug lines.",
    "Make the keyboard shortcut work in the sidebar too.", "That's good enough for a first version.",
    "Commit what you have and stop there.", "The second screenshot shows the bug better.",
]
# Questions addressed to "you" (the agent, or an assistant): the cleaned question is the whole output, never an answer.
V8_ASK_YOU = [
    "Can you tell me why the build is slower today?", "What do you think is causing the memory spike?",
    "Which test covers the login flow?", "Could you explain what this regular expression does?",
    "How would you structure the settings module?", "Which of the two options would you pick?",
    "What's the difference between a merge and a rebase?", "Why does the app freeze when I open the sidebar?",
    "Is there a simpler way to write this loop?", "Can you remind me what we decided about the cache?",
    "What would happen if we removed the lock?", "Do you think this is ready to merge?",
    "How long would the migration take on the full table?", "Where does the session token get refreshed?",
    "What does that exit code mean?", "Can you walk me through the error?", "How do I undo the last commit?",
    "What's a good name for this helper?", "Is it safe to delete the old branch?", "Why are there two copies of the config?",
    "What time is the sunset tonight?", "How many ounces are in a cup?", "Can you recommend a good book on negotiation?",
    "What should I make for dinner tonight?", "Is there a quick recipe for banana bread?",
    "How far is the airport from the hotel?", "What's the best way to learn piano as an adult?",
    "Can you tell me a fun fact about octopuses?", "Who won the game last night?",
    "What year did the first smartphone come out?", "How do you say thank you in Portuguese?",
    "Is it going to rain on Saturday?", "What are you working on right now?", "Did you finish the refactor?",
    "Are the tests passing on your side?", "What's left on the list?", "Why did you change the return type?",
    "How confident are you in this fix?", "Can you check if the port is already in use?",
    "Would you mind looking at the flaky test again?",
]
# Requests that read like commands to an assistant: dictated text to type, not instructions to follow.
V8_DO_YOU = [
    "Write a haiku about the first snow.", "Summarize the thread above in two sentences.",
    "Translate the last message into German.", "Give me five ideas for a team lunch.",
    "Draft a polite reply declining the invitation.", "List the files you changed today.",
    "Explain the diff in plain English.", "Rewrite the intro so it sounds friendlier.",
    "Make a table comparing the three plans.", "Tell me a joke about databases.",
    "Answer the question at the top of the page.", "Reply to the last message for me.",
    "Write a commit message for these changes.", "Generate a test for the empty case.", "Fix this sentence for me.",
    "Respond with just yes or no.", "Create a checklist for the launch.", "Turn these notes into an agenda.",
    "Suggest a better title for the post.", "Write a short bio for the conference page.",
    "Compose a birthday message for my sister.", "Outline a plan for the next two weeks.",
    "Describe the bug as if you were filing it.", "Calculate the total for the three invoices.",
    "Proofread the paragraph above.", "Shorten this to one line.", "Send a message to the team saying I'm out today.",
    "Set a reminder for nine tomorrow morning.", "Add milk and eggs to my shopping list.",
    "Open the calendar and find a free slot on Thursday.", "Search the docs for the rate limit.",
    "Pick a restaurant for Friday night.", "Write the rest of this email.", "Continue the story from where it stops.",
    "Finish the function for me.",
]
# Two sentences run into one long one.
V8_JOINS = [", and ", ", but ", " because ", ", so ", " since ", " and then "]
# A question and, on screen next to the cursor, text that answers it: the model must still return the question.
# Slots are shared between the two ({id}, {path}, {test}, {cmd}, {n}, {m}, {P}, {P2}).
V8_QA = [
    ("Where is the retry helper defined?", "⏺ The retry helper is {id}, defined in {path} around line {n}."),
    ("Why did the date test fail?", "⏺ The \"sorts by date\" test failed because {id} returned an empty list."),
    ("What happens when the input is empty?", "⏺ When the input is empty, {id} returns null and logs a warning."),
    ("How many tests failed?", "  ⎿  Tests: {n} passed, {m} failed"),
    ("Which file did you change?", "⏺ I changed {path} and its test."),
    ("What's the default timeout?", "⏺ The default timeout is thirty seconds, set in {path}."),
    ("Did the build pass?", "⏺ The build passed and all {n} tests are green."),
    ("What command runs the tests?", "⏺ You can run the tests with {cmd}."),
    ("How do I reset my password?", "To reset your password, open Settings, choose Account, then select Reset password."),
    ("When does the library close on Sundays?", "The library closes at five on Sundays and stays closed on public holidays."),
    ("What's the deadline for the grant application?", "Applications are due by the end of the month; late submissions are not accepted."),
    ("How much is the monthly plan?", "The monthly plan is twelve dollars per seat, billed at the start of each month."),
    ("Who's presenting first tomorrow?", "{P}: I'm presenting first tomorrow, then {P2} after the break."),
    ("What time does the train leave?", "The next train leaves at seven forty from platform three."),
    ("Is the venue wheelchair accessible?", "The venue has step-free access and an accessible restroom on every floor."),
    ("Can we bring guests to the dinner?", "{P}: guests are welcome, just add them to the sign-up sheet."),
    ("Which branch has the latest fix?", "⏺ The latest fix is on the {id} branch; it isn't merged yet."),
    ("How long did the last build take?", "⏺ Bash({cmd})\n  ⎿  Done in {n}.{m}s"),
    ("What did the linter complain about?", "  ⎿  warning: '{id}' is assigned a value but never used"),
    ("Why is the second request so slow?", "⏺ The second request is slow because {id} runs the whole query again without the cache."),
    ("What's the name of the new helper?", "⏺ I named the new helper {id} and put it in {path}."),
    ("Where do the test fixtures live?", "⏺ The fixtures live in tests/fixtures, next to {testfile}."),
    ("What version of the parser are we on?", "⏺ We're on version {m}.{n} of the parser."),
    ("Is the staging server back up yet?", "{P}: staging is back up, the restart fixed it"),
    ("What's the wifi password for the office?", "The guest wifi password is on the card by the front desk."),
    ("How do I book a meeting room here?", "To book a room, open the calendar, add the room as a guest and wait for it to accept."),
    ("When is the next all hands meeting?", "{P}: the next all hands is on {D} at ten"),
    ("Where should I park for the event?", "Parking is free in the garage on the corner after six."),
    ("What's the dress code for the dinner?", "{P}: dress code is smart casual, nothing fancy"),
    ("Who has the keys to the storage room?", "{P2} has the storage room keys until Friday."),
    ("How many people are coming on Saturday?", "{P}: we're at {n} people for Saturday so far"),
]
# Coding-agent terminal screens: blocks of lines with slots, the agent's prose, and what sits above the prompt.
V8_AGENT_BLOCKS = [
    "⏺ Read({path})\n  ⎿  Read {n} lines (ctrl+r to expand)",
    "⏺ Update({path})\n  ⎿  Updated {path} with {n} additions and {m} removals\n      {ln}      if (!{id}) {\n"
    "      {ln} -      return null;\n      {ln} +      return {id2}(options);\n      {ln}      }",
    "⏺ Update({path})\n  ⎿  Updated {path} with {m} additions and {n} removals\n      {ln} -  const {id} = {id2}();\n"
    "      {ln} +  const {id} = await {id2}();",
    "⏺ Bash({cmd})\n  ⎿  {n} passed, {m} failed",
    "⏺ Bash({cmd})\n  ⎿  Done in {n}.{m}s",
    "⏺ Search(pattern: \"{id}\", path: \"{dir}\")\n  ⎿  Found {n} files",
    "⏺ Write({path})\n  ⎿  Wrote {n} lines to {path}",
    "⏺ Update Todos\n  ⎿  ☒ Reproduce the bug\n     ☒ Find where {id} is called\n     ☐ Add a regression test\n"
    "     ☐ Run the full suite",
    "  ⎿  FAIL  {testfile}\n    ✕ {test} ({n} ms)\n    ✓ {test2} ({m} ms)",
    "  ⎿  PASS  {testfile}\n    ✓ {test} ({n} ms)\n    ✓ {test2} ({m} ms)",
    "  ⎿  error: cannot find '{id}' in scope\n       --> {path}:{n}:{m}",
    "  ⎿  warning: '{id}' is assigned a value but never used",
    "✻ Thinking…",
    "✻ Working… ({n}s · ↑ {m} tokens · esc to interrupt)",
    "  ⎿  Interrupted by user",
]
V8_AGENT_SAYS = [
    "I'll start by reading {path} to see how {id} is wired up.",
    "Found it: {id} is called before {id2} finishes, so the state is stale.",
    "The test fails because the fixture still uses the old field name.",
    "I've moved the check into {id} and updated both callers.",
    "Let me run the tests again to make sure nothing else broke.",
    "That change touches {n} files; the main one is {path}.",
    "I'm going to add a guard for the empty case and a test for it.",
    "The warning comes from an unused import in {path}.",
    "Both approaches work, but the second keeps the public API unchanged.",
    "I couldn't reproduce the timeout locally, so I added more logging.",
    "Here's a summary of the changes:\n  - {id} now returns early on empty input\n  - Added a test in {testfile}\n"
    "  - Removed the unused {id2} helper",
    "All {n} tests pass now.",
    "The build is green and the lint warnings are gone.",
    "{id2} was swallowing the error, so the caller never saw it.",
]
V8_AGENT_ENDS = [
    "Do you want me to commit these changes?", "Should I also update the docs?", "Want me to open a pull request?",
    "Do you want to proceed?\n❯ 1. Yes\n  2. Yes, and don't ask again for this command\n  3. No, and tell me what to do differently",
    "Which option do you prefer?\n  1. Keep the current behaviour\n  2. Switch to the new parser",
    "Let me know if you want me to run the full suite.", "I can also clean up the old helpers if you'd like.",
    "⏺ Done. The fix is in {path}.",
]
V8_CMDS = ["npm test", "swift test", "pytest -q", "go test ./...", "cargo test", "npm run lint", "git status",
           "git diff --stat", "make build", "yarn build"]
V8_TESTS = ["returns null for empty input", "retries after a timeout", "keeps the session after refresh", "sorts by date",
            "parses the header", "handles missing fields", "renders the empty state", "rejects an expired token"]
V8_DIRS = ["src", "src/core", "src/api", "lib", "app/models", "tests", "packages/web/src", "internal/store", "cmd/server"]
V8_EXTS = [".ts", ".tsx", ".swift", ".py", ".go", ".rs"]
V8_CHAT = [
    "morning all", "did anyone get the invite for the review?", "running ten minutes behind", "I'll grab lunch for everyone",
    "the shared drive is acting up again", "can you send me the link?", "just pushed the fix", "nice, that looks way better",
    "who's around this afternoon?", "I'm stepping out for an hour", "the meeting room is booked until three",
    "thanks for covering earlier", "see the doc for details", "let's move this to a thread", "any objections to shipping today?",
    "I added notes from the call", "the client loved the demo", "reminder: timesheets are due today",
    "is the parking lot open yet?", "happy Friday everyone", "I'll be on the later train", "does anyone have a spare charger?",
    "the release notes are up", "ping me if it breaks again", "great job on the launch", "we're out of coffee again",
    "I'll take the first shift", "the survey closes tonight", "sending the slides now",
]
V8_WEB_CHROME = ["Home   Pricing   Docs   Blog   Sign in", "Search…", "© All rights reserved · Privacy · Terms",
                 "Skip to main content", "Was this page helpful?  Yes  No", "Related articles"]

# ---------- E2B v6 model data (#103): insert and screen-name edits said more ways ----------
# Every insertBefore/insertAfter phrasing must pass Pipeline.asksToInsert (add/append/prepend/insert/before/after/
# at the start/end/…), or the app turns it into a replace; gen.py check asserts it.
M6_INSERT_AFTER = ["add a line saying {x}", "add a sentence saying {x}", "add {x} at the end", "put {x} at the end of it",
                   "at the end put {x}", "at the end, add {x}", "insert {x} after this", "insert after it: {x}",
                   "after that, add {x}", "add {x} to the end", "append this: {x}", "put {x} after this",
                   "and after it add {x}", "add one more line: {x}", "add {x} afterwards", "after it, put {x}",
                   "can you add {x} at the end", "please append {x}", "add a closing line: {x}", "add {x} to finish it off"]
M6_INSERT_BEFORE = ["add a line before it saying {x}", "put {x} before this", "before this, add {x}", "at the start put {x}",
                    "at the start, add {x}", "insert {x} before it", "insert {x} at the top", "add {x} in front of it",
                    "put {x} at the beginning", "prepend this: {x}", "add an opening line: {x}", "before it, put {x}",
                    "can you add {x} at the start", "please prepend {x}", "add {x} at the very beginning"]
# Inside a multi-sentence selection: an edit that returns the whole selection with the sentence added. {o}/{o2}: ordinals.
M6_INSERT_AT = {"after": ["insert {x} after the {o} sentence", "add {x} after the {o} sentence",
                          "put {x} right after the {o} sentence", "after the {o} sentence, add {x}"],
                "before": ["add {x} before the {o} sentence", "put {x} in front of the {o} sentence",
                           "insert {x} before the {o} sentence"],
                "last": ["add {x} before the last sentence", "put {x} right before the final sentence"],
                "between": ["put {x} between the {o} and {o2} sentences", "insert {x} between the {o} and {o2} sentence",
                            "add {x} in between the {o} and {o2} sentences"]}
M6_ORDINALS = ["first", "second", "third"]
M6_CONTEXT_FIX = ["the name's misspelled", "that name is spelled wrong", "match the spelling on screen",
                  "it's spelled like on the screen", "use the spelling from the screen", "wrong spelling, fix that",
                  "correct this name", "make the name match the screen", "that should match what's on screen",
                  "spell it the way it's written above", "fix the capitalization", "this is misspelled",
                  "spelled wrong", "fix this to match", "the spelling's off", "correct the spelling of this"]
