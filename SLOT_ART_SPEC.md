# High 5 Games: Slot Art Reference Specification

Research date: 18 September 2026. Scope: symbol planning, art direction, generation, and animation-ready delivery.

**CRAFT — Status and use.** This is a proposed internal working specification, not a claim that every recommendation is already H5G production policy. Use the approved game design for mechanics, the approved theme and art reference for appearance, and the target runtime contract for delivery. Use this document to resolve art decisions those sources leave open. Do not let a generic role prompt override a game's explicit design.

**CRAFT — Claim labels.** **EVIDENCE** identifies an inspectable source or direct observation; it establishes what that source demonstrates, not a universal rule. **CRAFT** identifies an art-direction judgement or a pipeline choice proposed here, with its rationale. **UNVERIFIED** identifies a claim or project-specific fact not established. A label on a table, list, or prompt block applies to all its contents unless a row says otherwise. External references were consulted on the research date; PDF page numbers below are one-based.

**UNVERIFIED — Limits.** No controlled player-recognition study, complete H5G production export contract, or representative market-wide art survey was established. Public artwork is evidence of appearance, not evidence of its original authoring resolution, layer structure, or psychological effectiveness. Named examples are precedents, not assets licensed for reuse.

## Audit: what this replaces

**EVIDENCE — Local sources inspected.** The legacy [slot_design.md](/Users/merickson/Downloads/design2asset-0ea1c4eb/slot_design.md) is 420,158 bytes and 5,529 lines. It was inspected through targeted searches and section reads. The current [SlotArtDirection](/Users/merickson/NavigatorApp/NavigatorCore.swift:6637), including all four requested members, and the adjacent GDD extraction and theme structures were read. Line references describe the inspected working copy, not a released version.

| Classification | Verified finding | Disposition |
|---|---|---|
| **EVIDENCE → CRAFT** | Legacy lines 2900–2908 prescribe solid fills and removal of gradients, bevels and dimensional effects; 3006–3022 condemn photorealistic and soft rendering. But 3143, 3488 and other passages permit gradients. | Replace the contradictory medium restrictions with reference-matched rendering and actual-size review. |
| **UNVERIFIED** | A literal blanket prohibition using the word “painterly,” or an empirical basis for dating these constraints specifically to 2012, was not established. | Do not repeat that historical explanation as fact. The flat-art pressure is demonstrable without it. |
| **EVIDENCE → CRAFT** | Line 4640 recommends 256×256 source; 4641 calls 512×512 high quality. | Remove as universal authoring guidance. Separate master, runtime and display dimensions (§7). |
| **EVIDENCE → UNVERIFIED** | Line 333 specifies recognition within 200 milliseconds at 32×32; line 102 specifies 85% silhouette recognition; 212 and 2709–2820 give percentage “contrast ratios.” No supporting study, metric definition or test protocol accompanies them. | Delete the thresholds. Do not replace them with different invented numbers. Use the review procedure in §4. |
| **EVIDENCE → CRAFT** | Lines 199 and 2590–2666 prohibit human MPs and prescribe wild energy, scatter portals, bonus containers and mathematical-looking multipliers. | Replace with mechanical definitions and shipping counterexamples (§§1–3). |
| **EVIDENCE → CRAFT** | Lines 42–128 prescribe eye area, crop/fill percentages and ornament counts; 284, 351 and 972 prescribe facet counts. | Delete as acceptance criteria. Compose to the cell, subject and approved reference; facets describe material, not payout. |
| **EVIDENCE → CRAFT** | Swift's houseStyle permits painted work. setRules still bans human MPs and fixes wild/scatter/bonus archetypes, while direction(for:tier:) explicitly contradicts those rules. | Use one consistent rule set; do not append the new blocks to contradictory legacy prompts. |
| **EVIDENCE → CRAFT** | setRules requires one detail level, but setConsistency permits variation. HP direction assumes four tiers and a fixed crop/gaze ladder. | Keep one rendering treatment; allow controlled detail variation and the actual number of tiers. |
| **EVIDENCE → CRAFT** | Swift merges collector/activator, makes R an unremarkable LP-like stand-in, and sends unknown roles toward medium-pay art. | Read feature semantics; an unknown role remains unresolved. R may need no distinct picture. |
| **EVIDENCE → CRAFT** | Swift's 8% margin, 3–6 animation parts, half-symbol WY plate and upper-left light are unsourced defaults. | Replace fixed margin/part-count/plate-area rules with explicit per-project measurements. Upper-left light remains an optional house default, not industry law. |
| **EVIDENCE → CRAFT** | Swift assumes a dark, busy reel field and describes all jackpots as one four-tier family. | Test the actual reel fields. Use the game's actual jackpot count and presentation; the shared family is a recommendation, not a universal observation. |

## 1. What a slot symbol set is

**CRAFT — Working model.** A symbol set is a collection of game identities and their visible states, not simply a folder of differently priced pictures. Track separately: source identity/code, evaluation rule, feature action, payout rank, visual subject, runtime text, and state variants. One identity can have several roles; several identities can reuse one artwork.

**EVIDENCE — Roles overlap.** In Book of Dead, the scatter also substitutes as a wild and triggers free spins. In Big Bass Bonanza, the fisherman is a wild with a money-collection function. These invalidate mutually exclusive visual archetypes. [Book of Dead rules, p. 1][BODRULES]; [Big Bass launch description][BASS].

**CRAFT — Local terminology contract.** The following meanings are the planning vocabulary for this tool. The codes reflect Navigator's local conventions, not an international naming standard. Resolve each entry against the specific GDD and paytable before generation.

| Role | What it does mechanically | What must be known before drawing |
|---|---|---|
| **HP / HP tiers** | Ordinary paying symbols in the high band of that game's payout schedule. Rank concerns comparable winning combinations, not likelihood of landing. | Actual order, ties, any split/stacked/expanded states, subjects from the art brief. Never infer four HPs. |
| **MP** | Ordinary paying symbols in an intermediate band, when the design uses one. It is not a separate evaluation mechanic. | Whether an MP band exists; position relative to HP/LP. People, animals and objects are all eligible subjects. |
| **LP** | Lower-band ordinary paying symbols. Not “non-paying,” necessarily most frequent, or necessarily card ranks. | Family, actual payouts and identity distinctions. Frequency comes from the game design, not the artwork. |
| **WD** | Substitutes for eligible symbol identities during win evaluation. May also pay itself or carry additional functions. | Substitution exclusions, own pay, restrictions, multiplier/collector behavior, expansion or persistence. Substitution need not be depicted as a physical transformation. |
| **SC** | Evaluated by a scatter/count rule rather than an ordinary connected payline. Exact permitted positions/reels and counts are game-specific. | Whether it pays, triggers something, or both; permitted positions and upgraded variants. “Anywhere” must not erase reel restrictions. |
| **BO** | Causes or contributes to entry into a bonus feature. “Bonus” describes a function, not an evaluation rule. | What event it triggers and how it qualifies. It can be the same identity as SC; a separate BO image is not automatically required. |
| **SF: collector** | Aggregates eligible values/items into a destination or awards them according to the feature rule. | What is collected, from where, to where, whether sources remain, and whether it repeats. |
| **SF: activator** | Starts an action, unlocks a state or invokes another feature. It need not collect anything. | Trigger, target, resulting state and whether it needs its own reel identity or is an overlay/UI action. |
| **SF: adder** | Adds a specified quantity to eligible values, a meter, spins or other targets. | Unit, eligible targets, timing and persistence. “Adds 2× bet” is an amount increment, not necessarily doubling. |
| **SF: multiplier** | Scales a specified target by a factor. | Target: one value, selected symbols, a line win, tumble total or round total; combination and persistence rules. Route to MU art direction. |
| **JP / tiers** | Identifies, qualifies for, or reveals a named jackpot/prize tier under the game's rules. Landing it need not pay immediately. | Tier names/order, fixed vs progressive, qualifying behavior, and whether these are reel symbols, pick reveals or meters. |
| **WY: cash-on-reel / WYSIWYG** | Carries a displayed cash, credit or bet-multiple value used by a feature. A displayed value is not a promise of immediate payment. | Unit, value range, collection/qualification rule, text location and state changes. |
| **R: replacement** | Local code for an identity used in a replacement/mystery-resolution process. The code alone does not specify when, what or whether the player sees it. | Pre-reveal visibility, target set, timing and whether art is reused. Not synonymous with WD. |
| **BL: blank** | Explicit empty/non-picture position in the game model. | Whether the runtime needs no image or a transparent placeholder. Never invent decorative “blank” art. |
| **MU** | Multiplier-bearing identity, as above; it may also be WD, SF or another role. | Factor display versus artwork, operation scope, stacking rules and active/spent states. |

**EVIDENCE — H5G nuance.** Golden Goddess describes “Bonus scatter symbols” restricted to reels 2, 3 and 4, and substitution of a selected identity into reel stacks. Shadow of the Panther explicitly describes mystery stacks transforming at spin start. These demonstrate why SC and BO can overlap, and why replacement behavior is not a generic visible low-pay object. [Golden Goddess rules, pp. 1–2][GODDESS]; [Shadow of the Panther rules, pp. 4, 8][PANTHER].

**CRAFT — Scatter versus bonus.** Store these as separate facts: “count three in eligible positions” and “start free spins.” Draw one asset if one game identity does both. If the GDD specifies distinct scatter and bonus identities, give them distinct subjects or unmistakable interior marks. Do not create two assets just because two words occur.

**EVIDENCE — Rank numbering is not portable.** Book of Dead's published table places HP4 above HP3, with HP2 and HP1 tied. Its published HP4 artwork is Rich Wilde. [Rules, pp. 4–5][BODRULES]; [official symbol gallery][BOD]. **CRAFT:** Preserve codes verbatim and store verified rank separately. A suffix is an identifier until the project's convention is established.

## 2. Value hierarchy: what the artwork can communicate

**UNVERIFIED — Exact unaided ranking.** No evidence reviewed establishes that players can reliably sort every symbol into exact payout order without instruction. The paytable remains authoritative. Art should make broad value bands and special functions legible; it must not claim to replace the rules.

**EVIDENCE — Observed devices, not measured causes.**

| Device | Shipping observation | Scope of the evidence |
|---|---|---|
| Subject identity / desirability | Book of Dead puts Rich Wilde above its other ordinary symbols. His portrait wears ordinary clothing, rather than the most gold in the set. [BODRULES][BOD] | A signature character can outrank ornate objects. It does not prove a universal preference for faces. |
| Material | Divine Fortune Gold explicitly partitions cash prizes into bronze, silver and gold value bands. [DIVINE] | A material ladder can carry an explicit game distinction. |
| Ornament / frame | Book of Dead's premiums have decorated rectangular surroundings; its royals have simpler standalone gold-edged letterforms. [BOD] | A shared construction distinguishes families. Decoration is not a numeric payout scale. |
| Colour | Gems Bonanza's highest gem is red; cyan ranks above orange. [Gems paytable, p. 1][GEMS] | Colour can support rank within a design but cannot supply a universal warm-to-cool ordering. |
| Light / contrast | Book of Dead GO Collect's jackpot coins use modelled gold, shaded gems and large contrasting tier lettering. [COLLECT] | Highlights and contrast are visible treatments; their effectiveness was not measured. |

**EVIDENCE — “Warmer = higher” has examples and counterexamples.** In the inspected Gems Bonanza paytable, red is top and blue is bottom. However, at the five-symbol count, cyan pays 5 and orange 4 in the table's units; green pays 6. Warmth is therefore not monotonic even within this one game. In Money Train 2, the platform's published table orders red above orange above green above blue for five matching characters, an example of the convention working locally. [GEMS, p. 1][GEMS]; [Money Train 2 platform paytable][MT2PAY].

**CRAFT — Recommendation.** Use subject significance and the theme's own material vocabulary as the primary hierarchy. Support them with differentiated ornament, focal contrast and controlled accent colour. Use warm premium accents when they suit the game; keep ice, moonlight, chrome or blue-fire premiums cool when those subjects demand it. Never recolour an approved subject merely to obey a temperature ladder.

**CRAFT — Concrete ladder design.** Write the visible difference between neighboring bands before generating: for example, “HP: ceremonial artefacts with a dominant gemstone; MP: working tools with modest metal fittings; LP: simple enamel marks.” This is an invented art-direction example, not a shipping-game fact. Keep equal-paying siblings comparable in prominence. Within a band, vary subject identity first; do not add arbitrary jewels to manufacture ranks the paytable does not contain.

**CRAFT — Separate attention from value.** A trigger may deserve conspicuous colour without paying more than HP1. A wild need not be brighter than every jackpot. Allocate distinct attention cues by function; demanding “highest contrast” independently for WD, SC, BO and JP cannot establish a coherent hierarchy.

## 3. Per-role art direction

**CRAFT — Common decision.** Pick a specific subject from the approved theme, then adapt its composition to the actual role. The examples establish possibilities; they are not instructions to copy another game's IP.

### HP, MP and LP

**EVIDENCE — HP precedent.** Book of Dead uses a human adventurer among Egyptian premium imagery. H5G's Shadow of the Panther combines portrait and animal imagery with dimensional jewelled objects; its published bonus paytable also contains tied premium values. Neither supports a mandatory ruler/crop/ornament ladder. [BOD]; [PANTHER, p. 2][PANTHER].

**CRAFT — HP.** Draw the game's most compelling approved subjects with clearly described forms and focal detail. A character, animal, vehicle, treasure or graphic mark can lead the set. Do not require metallic skin, royalty, angular geometry, frontal eyes or a head-only crop. Increase importance through subject and presentation, not indiscriminate decoration.

**EVIDENCE — Human middle ranks.** Money Train 2's published platform paytable puts blue, green and orange characters between its card suits and highest red character; Relax's own description and imagery identify a cast of bandits. This is a concrete human-character middle range. [MT2PAY]; [Relax's game page][MT2]. **UNVERIFIED:** The sources do not establish that Relax internally names these characters MP1–MP3; do not relabel a competitor's production codes.

**CRAFT — MP.** Use a human supporting character if appropriate. Make the intermediate band visible through a restrained costume/material/detail budget relative to the chosen HP treatment, not through a species ban or a mandatory curved silhouette. If the game has only high and low bands, generate no additional MP band.

**EVIDENCE — LP precedent.** Book of Dead publishes royals as its low family; Reactoonz publishes low-pay creature assets. Lower value does not require typography or inanimate objects. [BOD]; [Reactoonz official gallery][REACTOONZ].

**CRAFT — LP.** Choose a cohesive family as the default: royals, gems, fruit, creatures or simple thematic objects. Differentiate identities by shape or interior design as well as colour. Use fewer competing forms and broader detail, but keep the same finish quality. A deliberate mixed family is allowed if the approved reference supports it; “never mix” is not an industry rule.

### WD, SC and BO

**EVIDENCE — WD precedent.** Big Bass Bonanza's fisherman supplies wild behavior; Book of Dead combines wild and scatter in its book. A generic energy burst is unnecessary. [BASS]; [BODRULES].

**CRAFT — WD.** Use a memorable theme subject, wordmark or emblem. Preserve recognition through any expanding, sticky or multiplier states. Reserve a text zone only if the interface requires a WILD label. Do not force magic, transformation, motion streaks or a universal lower-third banner.

**EVIDENCE — SC precedent.** Gates of Olympus 1000 explicitly uses Zeus scatter symbols. Big Bass Bonanza uses hooked bass scatters. Neither is a doorway. [GATES]; [BASS].

**CRAFT — SC.** Make repeated instances easy to spot and count across the actual grid. Give it a distinct dominant subject and recognisable interior structure even if the family frame is shared. Do not force circles, portals or a FREE SPINS label when the symbol has another purpose.

**EVIDENCE — BO precedent.** H5G's Beat the House triggers a pick bonus with soundboard symbols. Golden Goddess's bonus scatter has a combined mechanical role. [BEAT]; [GODDESS].

**CRAFT — BO.** Draw the subject that represents this particular feature: an instrument, character, emblem, prize object or container as appropriate. A feature trigger need not invite a click, and a bonus need not involve manual selection. If BO and SC are distinct identities, separate them; if they are the same identity, share the art.

### SF and MU

**EVIDENCE — Distinct operations.** Divine Fortune Gold's collector aggregates cash prizes; its Adder increases selected cash prizes, then becomes a cash prize. Its published adder art is a purple, gold-rimmed disc, not a mandatory device. Money Train 2 uses a character cast for collecting, paying out value and doubling targets. [DIVINE]; [MT2]; [Money Train 2 feature rules][MT2RULES].

| Role | **CRAFT — Draw** | **CRAFT — Avoid** |
|---|---|---|
| SF collector | A theme actor, object or emblem with room for a collected-value display if needed. Stage motion from eligible sources toward the collection destination. | A compulsory jar, vacuum or machine; assuming collection deletes sources. |
| SF activator | A subject tied to the invoked feature, plus planned inactive/triggered states if they are visible. Specify the thing it activates. | Calling it a collector because it has an SF code; showing accumulated cash when none exists. |
| SF adder | A distinctive subject with a quiet increment zone. Use authored “+” notation when it communicates the real operation. Stage motion outward toward recipients. | A multiplication sign for addition; a progress fill that misrepresents an increment as collection. |
| MU / SF multiplier | A theme-consistent carrier for a clear authored factor. Make its target and affected state clear in the animation/UI plan. | Mandatory circuitry, precise rays or “mathematical energy”; confusing a cash amount expressed in bet multiples with an operation on other values. |

**EVIDENCE — Activator precedent.** Beat the House's beat symbols leave highlighted boxes, and filling a reel changes it to a locked wild: activating/changing the field is distinct from gathering cash. [BEAT]. **CRAFT:** Base the activator drawing and feedback on that action, not the generic noun “special.”

**EVIDENCE — Multiplier precedent.** Gates of Olympus 1000 uses multiplier symbols in the win process; Money Train 2's Sniper doubles selected values. Multiplication can be carried by a symbolic effect or a character. [GATES]; [MT2RULES]. **CRAFT:** Let the theme choose the carrier, and let authored notation and animation explain the operation.

### JP: one family or four objects?

**EVIDENCE — Inspected four-tier construction.** Book of Dead GO Collect publishes GRAND, MAJOR, MINOR and MINI assets with the same irregular gold coin, engravings, central gem and large tier-name position. Gems/lettering differ: red-orange, turquoise, purple and lime respectively. See the [official gallery][COLLECT] and its [Grand][JPGRAND], [Major][JPMAJOR], [Minor][JPMINOR] and [Mini][JPMINI] assets.

**CRAFT — Decision.** Default to **one shared construction with distinct tier treatments**, not four unrelated treasures. Reuse geometry and text placement; differentiate the tier name, accent and, where useful, a secondary ornament or interior mark. The reasoning is practical: the player sees one prize system, and production can keep geometry and animation aligned.

**CRAFT — Exceptions.** Use distinct objects if the approved game's fiction and UI already establish them as a ranked collection. Keep a common badge/label grammar and persistent tier names. Different objects do not excuse guessing which tier is higher; hue alone does not solve that either. The shared-family recommendation is a choice supported by a precedent, not a prevalence study.

**EVIDENCE — Count is not always four.** H5G's Platinum Goddess Jackpot lists Grand, Major and Minor as three progressive network jackpots. [PLATINUM]. **CRAFT:** Do not generate a Mini, assume fixed prizes, or create reel symbols for a meter-only jackpot system unless the design requires them.

### WY, R and BL

**EVIDENCE — WY precedent.** Big Bass Bonanza attaches monetary values to fish and requires feature behavior to collect them. The value carrier need not look like a cash register or rectangular plaque. [BASS].

**CRAFT — WY.** Start with the longest real formatted value, its font and placement. Fit the theme subject around that readable region. Keep the text upright and clear; use a plate only when needed. Generate the body without dynamic numerals, currency marks or baked-in payout claims. Do not reserve an arbitrary half of every image.

**EVIDENCE — R precedent and limit.** H5G's Shadow of the Panther describes mystery positions transforming into ordinary identities. It does not publish an internal R-code art contract. [PANTHER, p. 8][PANTHER]. **CRAFT:** If R resolves before visibility, reuse the target art and generate nothing extra. If there is a visible mystery state, design that state and its reveal. **UNVERIFIED:** Whether a particular H5G R code is visible remains a GDD/runtime question.

**EVIDENCE — BL precedent.** IGT's Double Diamond rules explicitly discuss outcomes containing blank symbols. [Platform-published game rules][BLANK]. **CRAFT:** Represent emptiness with no illustration; preserve the logical slot in the manifest. A technical transparent image is a runtime decision, not a new art subject.

## 4. Set coherence

**CRAFT — Judge the set before polishing individuals.** Establish a reference sheet with an HP, an LP and a feature symbol on the actual reel field. Approve their common treatment, then supply that same reference and the locked set brief to every generation request. A text adjective such as “premium” cannot specify a paint treatment by itself.

**CRAFT — Lock these decisions explicitly.**

| Set property | Prompt-ready specification to record | Why |
|---|---|---|
| Rendering | Medium, degree of stylisation, surface finish and representative reference image. Example: “painted realism, simplified large forms, selective sharp highlights, no black cartoon outline.” | Prevents realistic skin, plastic jewellery and flat vector letters from becoming unrelated styles. |
| Lighting | Key direction and softness; fill/shadow hue; rim-light policy; intensity of material highlights. Use upper-left as a fallback only when no reference establishes another direction. | Shared lighting makes forms occupy the same visual world. |
| Emissive exceptions | Name which elements emit light and where that light spills. Keep the base key consistent elsewhere. | A magic symbol need not obey an impossible ban on local illumination. |
| Palette | Named base colours/materials, accent roles, forbidden accidental accents, reel/background colours. Record approved swatches rather than asking for arbitrary saturation percentages. | Palette discipline is controlled relationships, not making every symbol the same colour. |
| Edge treatment | Painted cutout, outline, bevel or frame; consistency of softness and highlight/shadow transitions at display size. | Mismatched edges often expose mixed sources. |
| Optical weight | Reference for visible body size, centre of mass, face scale and frame footprint; explicit exceptions for tall/thin forms. Exclude transparent margins and FX halos from body comparison. | Equal canvas occupancy can make a sword look tiny beside a disc. |
| Detail by tier | Where detail is concentrated; which surfaces stay quiet; allowed ornament differences. | HP can be more elaborate without becoming a different rendering medium. |
| Perspective | Camera height, projection/depth exaggeration and angle family. | A top-down cup beside a flat side-view vehicle can feel assembled from different games. |
| Typography/frame | One approved font treatment, label location family and frame construction, with deliberate exceptions identified. | Repeated interface elements should not mutate across generations. |

**CRAFT — Review procedure, replacing invented thresholds.**

1. Show the full set at the smallest supported reel-cell size and at normal play size, on base and feature backgrounds. Include a plausible crowded grid, not only isolated large assets.
2. Check identity confusion, countability of triggers, label readability and optical balance. Record the actual confused pairs and conditions.
3. Inspect greyscale and colour-vision simulations as diagnostics. If colour distinctions collapse, strengthen shape, interior structure or text.
4. Use a silhouette view to find weak massing, not as a universal pass/fail test. Shared rectangular portraits cannot be identified from their outer silhouette alone.
5. Check repeated symbols, reel-edge clipping and animation extremes. A shape that reads alone may merge into an adjacent copy.
6. Record revisions and review again with the set. If formal recognition performance is needed, define participants, exposure, task, device and error metric before measuring; do not report a made-up percentage.

**CRAFT — Approval criterion.** Approve when reviewers can distinguish required identities and read their functional text in the intended contexts, with no unresolved mechanical or production ambiguity. Do not require exact unaided rank guesses between equal or closely ranked pays.

## 5. Frames, plaques and backing plates

**EVIDENCE — Shipping use.** Book of Dead's published premium assets have a common rectangular frame/backing, while its low royals are standalone. Gems Bonanza's wild has a square gold construction around a green gem, unlike the regular gem shapes. Shared exterior silhouettes demonstrably coexist with differentiated interiors. [BOD]; [GEMS, p. 1][GEMS].

**CRAFT — Distinguish four things.** A frame borders the subject. A backing plate provides a field behind it. A plaque carries text/value. A generation backdrop is temporary and must be removed. Confusing a designed backing plate with a removable background can destroy the asset.

**CRAFT — Use a frame when** it establishes a family, stabilises a portrait crop, separates the subject from a complex reel background, or provides a consistent label position. Omit it when it crowds the subject, conceals important shape differences or conflicts with the approved game look. Neither framed nor unframed is intrinsically more modern.

**CRAFT — Generate together for the approved concept; separate for reusable production.** A one-piece concept helps establish the relationship of subject, border and lighting. If the frame is shared or the subject will move independently, author one reusable frame/backing and separate the subject, foreground rim, plaque and FX as needed. Match contact shadows to the assembly. Do not regenerate nominally identical frames independently and accept drifting corners, gems and bevels.

**CRAFT — Cutout and animation contract.** Remove only the declared generation backdrop. Preserve intentional interior backgrounds and holes. For a portrait behind a frame, specify the mask boundary, whether head/prop may overlap it, and what stays visible during motion. Restore hidden paint behind moving parts. A flat cutout is a static deliverable until this separation and reconstruction are complete.

**CRAFT — Text.** Dynamic values and localised labels should be authored/rendered separately by the tool or runtime. A permanent stylised wordmark may be authored as approved artwork. Never rely on generated pseudo-lettering. Match the final font and longest string before approving a text zone; a blank-looking plate is not proof that the real label fits.

## 6. Composition and pose

**EVIDENCE — Face-on precedents.** GO Collect's jackpot coins and the Gems Bonanza gem constructions are frontal. [COLLECT]; [GEMS]. **CRAFT:** Face-on is legitimate; do not equate orientation with clip-art quality.

**CRAFT — Crop to the identity.** Use a head/shoulders crop when expression and costume establish a character. Use a bust or full figure when a tool, gesture or species needs it. Keep meaningful extremities inside the agreed safe area unless an approved framed crop deliberately cuts them. Cropped portraits need a designed lower edge or backing, not an accidental floating torso.

**CRAFT — Angle and eyeline.** Choose frontal views for symmetry, masks, insignia, animals looking toward the player, and readable value carriers. Choose three-quarter views when they reveal characteristic depth or attitude. Use profile when its shape is distinctive. Gaze is a character choice; HP2 does not mechanically “defer” to HP1 by looking away.

**CRAFT — Action versus rest.** The stopped symbol needs a stable readable pose with personality. A lean, expression or purposeful prop angle may suffice. Save large movement for anticipation/win animation. Avoid motion blur, particles crossing labels and foreshortened hands that obscure the face. A calm animal, upright car badge or static treasure can be correct.

**CRAFT — Repetition and special geometry.** Compose stacks, split symbols and expanded states against their actual footprint. Do not stretch a square portrait to fill a tall reel unless that distortion is intended. Plan whether expansion repeats cells, reveals a larger painting or animates a growing object. An expansion mechanic does not require an elastic subject.

## 7. Technical delivery

**UNVERIFIED — Industry-wide pixel law.** No universal slot-symbol source resolution, margin percentage, atlas page limit or animation layer count was established. The legacy 256×256 claim is not an adequate master-art standard. A publisher's web PNG dimensions are not proof of its production master dimensions.

**CRAFT — Proposed H5G authoring defaults, not existing engine requirements.**

| Deliverable property | Proposed contract | Reason / override |
|---|---|---|
| Ordinary square master | 2048×2048 pixels, layered, for new raster authoring. | A practical editable master choice. Use larger when the maximum displayed/animated footprint needs it; smaller only by explicit project decision. Do not upscale a poor 256 image and call the result equivalent. |
| Non-square symbols | Preserve the approved cell or multi-cell aspect and coordinate space. | A square generation request does not define the runtime geometry. |
| Runtime dimensions | Derive from the maximum physical pixel footprint, including device density and win scaling. Record each supported scale. | Example calculation: 180 CSS pixels × device-pixel ratio 3 × animation scale 1.25 = 675 physical pixels across. This is arithmetic under stated assumptions, not a required H5G size. |
| Master colour / delivery | Work to an agreed sRGB target; preserve the layered master. Deliver RGBA PNG part images and a flattened reference composite. | Proposed predictable interchange. Confirm runtime handling rather than relying on an embedded profile. |
| Transparency | True alpha outside intended art; no checkerboard or chroma backdrop baked into delivery. | Inspect over light, dark and actual reel backgrounds to reveal fringes and missing semitransparency. |
| Subject safe area | Record an explicit rectangle in master coordinates and approved overflow/mask behavior. | No fixed 8% rule. Bounds must include visible resting art and account for motion separately. |
| Frame/text geometry | Record frame bounds, content mask, label safe rectangle, baseline and pivot/origin. | Enables reuse and prevents labels colliding with ornament. |
| Names | Preserve source code plus state and part in a stable naming convention agreed with the importer. | Avoid accidental aliasing, case differences and orphaned attachments. |

**CRAFT — Keep three margins separate.** Composition margin is space around the subject. Motion clearance is space needed during animation, possibly outside its resting cell. Atlas padding is texel separation between packed regions. Increasing canvas margin does not automatically fix atlas filtering; trimming may remove it.

**EVIDENCE — Spine packing facts.** Spine's texture-packer documentation exposes trimming, rotation, padding, edge duplication, alpha mode and output scales. Its example configuration uses maximum width/height 2048 and paddingX/paddingY 2. Those are example settings, not universal requirements. Premultiplied-alpha output requires matching runtime blending; bleed addresses transparent-pixel colour when using straight alpha. [Spine texture packing][PACK].

**CRAFT — Runtime contract.** Record allowed atlas size, scales, compression, filtering/mipmaps, rotation, trim offsets and alpha mode with the integration owner. Keep editable source straight-alpha; apply the confirmed export treatment once. Test packing at runtime size against actual backgrounds. Do not change alpha settings blindly to hide a fringe. A 2048 master does not imply a 2048 atlas region or a one-page atlas.

**EVIDENCE — Spine layer import.** Spine imports PSD layers as attachments and supports layer-name tags. It can scale and trim exported layers and use PSD guides for origin. Its documentation identifies unsupported Photoshop-rendered features such as layer styles and certain masks/adjustments unless appropriate pixel data or conversion is supplied. [Spine Import PSD][PSD].

**CRAFT — Separate by motion, not a quota.** Plan the animation first, then deliver the required pieces:

| Intended motion | Needed separation |
|---|---|
| Head turn/tilt | Head from neck/body; enough hidden neck/hair paint for the approved range. A large perspective turn may need alternate drawings, not just a rotated flat head. |
| Blink/look/expression | Appropriate eye/lid/pupil or alternate face attachments; no mandatory eye dissection for a symbol that only scales as a whole. |
| Hand/prop gesture | Prop, hand/arm segments and overlaps appropriate to the action. Reconstruct occluded surfaces. |
| Hair/cloth/wing movement | Contiguous paint extending under overlaps; enough surface for deformation and sensible pivot positions. |
| Jewel pulse/light sweep | Jewel or highlight/emission layers when independent control is required. Keep lighting coherent in the resting composite. |
| Opening object | Lid/door, body, contents, interior and foreground occlusion where needed. |
| Framed portrait | Backing, subject, foreground frame/mask and label; define which elements can cross the border. |
| Value collection | Body, text anchor, effect origin/target and active/spent variants; values remain runtime-owned. |

**CRAFT — Handoff acceptance.** Deliver the editable layered master, named part PNGs, reconstruction composite, origin/scale/mask notes and intended motion ranges. Reassemble the parts and compare to the approved static before rigging. Inspect overlap extremes for holes, seams and doubled shadows. A collection of opaque cut rectangles is not animation-ready separation. Lock Spine editor/export/runtime versions with the integration owner rather than assuming the newest version is compatible.

## 8. Reading a GDD into an asset list

**EVIDENCE — Formats in this tool's actual intake.** Navigator documents numbered/ranged lists from 4260 Dodge and 4400 Chevy-Hot; it also handles Word tables exported as bare codes and a prose extraction path. Its GameTheme structure supplies name, look, comparables and reference art separately. [GDDSymbolSetRules](/Users/merickson/NavigatorApp/NavigatorCore.swift:6387); [GameTheme](/Users/merickson/NavigatorApp/NavigatorCore.swift:6601); [prose extraction](/Users/merickson/NavigatorApp/NavigatorCore.swift:7499).

**UNVERIFIED — Original GDD coverage.** The original Drive GDDs behind those code comments were not inspected in this research. Their names/formats are evidence of the current tool's documented assumptions, not an independent audit of all H5G GDDs. Likewise, the assertion that a GDD contains “nothing” about subjects is too broad: feature prose may explicitly name a subject, colour or animation.

**CRAFT — Extraction procedure.**

1. **Find the authoritative set.** Read the symbol set, paytable, feature rules, presentation notes and revision context. Preserve source location and wording. Do not treat every mention of “symbol” elsewhere as a new identity.
2. **Expand explicit ranges inclusively.** “1–4 HP1–4” declares four identities. “2–5 // MPs” also declares four, not five and not MP2–MP5; distinguish set indices from code suffixes. If two ranges disagree, flag the conflict rather than silently adding or dropping entries.
3. **Recover table structure.** In Word exports, a bare code may be separated from its description by several lines. Reconstruct rows/columns from the document, including merged cells and headers. Do not attach the next arbitrary paragraph as its description.
4. **Read prose counts without inventing a roster.** “Four high-value symbols” creates four provisional entries, with generated identifiers explicitly marked provisional. “16 symbols total” alone does not justify four of each familiar role.
5. **Resolve roles from behavior.** Read what SF, R, WY and upgrades actually do. Record multiple roles for one code. Keep base/bonus differences and state-dependent substitutions.
6. **Verify rank from pay information.** Record ties and combination length. Do not infer payout order from suffix, illustration size, colour or document order.
7. **Separate identity count from production count.** Exclude true blanks from image generation; reuse common frames/targets; add required alternate states, expanded art and moving parts. Reel-strip frequency is not asset count. A numeric value range is not a request for one painting per amount.
8. **Join the approved art brief.** Take world, theme, characters, subject constraints and rendering from the approved theme hub/art direction/reference. A mechanic-only GDD cannot choose them. If absent, keep subject/style unresolved and create a clearly labelled proposal before batch generation.
9. **Reconcile.** Compare extracted identities to the declared total, feature references and visible states. Explain every difference. Never manufacture symbols to make totals match.

**CRAFT — Minimum planning record.** Each entry needs: source code/index; source excerpt/location; role(s); exact action and target; game state; verified rank or unresolved rank; proposed/approved subject and its origin; frame/label/value requirements; reuse group; visible variants; animation intent; delivery footprint; unresolved questions. Keep source facts separate from creative decisions.

**CRAFT — Worked extraction example (invented).** A design states WD1, HP1–4, LP1–5, SC1, SF1 “adds value to coins,” WY1 and BL1: 14 logical identities. That gives 13 nonblank identities, not automatically 13 unique painted files. SF1 is an adder despite Navigator's collector prefix default. WY values are runtime text, not separate paintings. Shared construction and additional visible states determine the final production asset count.

**CRAFT — Unknown handling.** Continue planning known entries while marking missing mechanics, counts or subjects unresolved. Do not draw an arbitrary medium-pay object for an unknown role. A plausible picture can hide an extraction mistake until integration.

## 9. Anti-patterns and their prevention

**CRAFT — Judgement, not a detector.** These are production failure patterns to review, not proof an image was made by AI. The preventive instructions are art-direction decisions.

| Failure | Specific preventive instruction | Why |
|---|---|---|
| Twelve different rendering styles | “Match the approved reference's paint treatment, material highlights, edge softness and camera; use the same set brief.” | Coherence requires shared treatment, not repeated quality adjectives. |
| Everything becomes a glowing gold medallion | “Draw the named subject; use only the assigned frame and effects. Keep these silhouette/interior distinctions.” | Automatic ornament collapses identity and hierarchy. |
| Every special is a vortex | “Express the approved feature subject; do not infer a portal, container or energy core from the role name.” | Mechanics do not prescribe metaphors. |
| Plastic faces and melted jewellery | “Keep material-specific highlights; simplify unsupported texture; correct anatomy, joins and ornament continuity.” | Surface gloss cannot substitute for convincing form. |
| Tiny detail masquerades as richness | “Concentrate detail at the focal feature; keep secondary surfaces broad; inspect at reel size.” | Large-preview polish may disappear in play. |
| Colour-only identities | “Change internal shape, subject mark or label as well as hue.” | Preserves distinctions when colours converge. |
| All symbols shout equally | “Use the agreed emphasis budget; reserve local accents by function.” | Uniform maximal contrast removes hierarchy. |
| Generated text and false values | “Leave the specified text zone clear; typeset the exact approved label/value separately.” | Prevents illegible lettering and invented game information. |
| Catalogue pose imposed on every subject | “Use the approved readable pose; choose frontal, profile or three-quarter for this subject's defining features.” | Both forced action and forced symmetry can weaken identity. |
| Background cutout destroys intended art | “Remove only the named backdrop; preserve backing plate, interior holes and semitransparent edges.” | Background and backing are different assets. |
| Fringes or lost fur after keying | “Choose a backdrop absent from the subject; inspect the extracted alpha on light/dark/reel fields and repair contamination.” | A nominal key colour is not safe for every palette or translucent surface. |
| Animation reveals holes | “Paint through overlaps within the planned motion range; reassemble and inspect extremes.” | Cropping existing pixels cannot recover hidden surfaces. |
| Expensive-looking lower pays reverse the ladder | “Compare the entire row to the verified rank plan; adjust focal material/ornament while preserving identity.” | Individual prompts cannot judge the set's relative emphasis. |
| Cultural ornament becomes pseudo-script | “Use approved reference motifs; omit unreadable invented inscriptions unless explicitly designed as fictional.” | Theme specificity needs deliberate motifs rather than decorative noise. |
| Familiarity becomes copying | “Use shipping examples to choose a treatment or function; design original approved subjects.” | A reference precedent is not a reuse instruction. |

## 10. Prompt-ready distillation

**CRAFT — Assembly contract.** Use the house block, set block, approved symbol brief and applicable role block(s). Resolve bracketed fields before sending; omit irrelevant clauses. Multiple roles share one subject brief. Do not send conflicting legacy blocks. Planner/extractor instructions belong to planning, not image generation.

### House / craft block

~~~text
CRAFT — HOUSE
Follow the approved theme and rendering reference. Draw one deliberate game symbol.
Keep a clear focal point, readable form and clean separation from the specified reel field.
Use convincing material response within the chosen style; allow painting, gradients and dimensional light.
Concentrate detail at the identity-defining feature. Keep secondary surfaces quiet.
Preserve the approved pose, crop, safe area and text zones.
Do not invent labels, numbers, extra props, frames or effects.
Keep the subject distinct from its named neighbours.
Remove only the declared temporary backdrop in final delivery.
~~~

### Set-coherence block

~~~text
CRAFT — SET
Match [reference]: [rendering], [key light], [fill/shadow], [edge treatment], [perspective].
Use [palette/materials] with [assigned accents]; follow [emissive exceptions].
Match [optical-weight reference], excluding margins and effect halos.
Use [frame/backing construction] and [label geometry] exactly where assigned.
Vary detail by [approved tier plan], never rendering quality.
Preserve these identity differences: [neighbour comparisons].
Compose for [cell aspect], [safe rectangle], [mask/overflow] and [animation intent].
~~~

### HP block

~~~text
CRAFT — HP
Draw [approved subject], rank [verified rank] within [actual premium count].
Carry importance through [subject/material/focal ornament].
Use [approved crop and pose]; keep defining features readable.
Match the set's optical scale. Do not infer royalty, frontal eyes or extra gold from HP.
~~~

### MP block

~~~text
CRAFT — MP
Draw [approved subject] between [higher band] and [lower band].
Use [intermediate material/detail treatment].
People, creatures and objects are eligible; preserve the approved subject.
Do not create this band unless the design calls for it.
~~~

### LP block

~~~text
CRAFT — LP
Draw [identity] in [approved low-pay family].
Use broad readable forms and the set's finish quality with restrained detail.
Distinguish it by [shape/interior mark] as well as colour.
Do not imitate a special symbol's label or feature treatment.
~~~

### WD block

~~~text
CRAFT — WD
Draw [approved wild subject] with [identity cue].
Preserve recognition through [specified states].
Reserve [label/factor zone] only when required.
Do not infer a vortex, transformation effect or portal from substitution.
~~~

### SC block

~~~text
CRAFT — SC
Draw [approved scatter subject] as a clear repeated identity across the grid.
Distinguish it from [ordinary symbols / separate bonus identity].
Use [approved mark or label zone] if required.
Do not infer a circular portal or a free-spins function.
~~~

### BO block

~~~text
CRAFT — BO
Draw [approved feature subject] representing [actual bonus].
Use the existing scatter artwork if this is the same game identity.
Otherwise preserve [distinguishing subject/mark].
Do not imply opening, clicking or collection unless the feature calls for it.
~~~

### SF collector block

~~~text
CRAFT — SF COLLECTOR
Draw [approved collector subject].
Keep [collection destination] and [required total zone] unobscured.
Prepare [active/spent/persistent states] only as specified.
Do not force a vessel or machine; do not invent disappearing source values.
~~~

### SF activator block

~~~text
CRAFT — SF ACTIVATOR
Draw [approved subject] associated with [activated feature].
Make [inactive/activated state difference] readable.
Preserve [effect origin or target cue].
Do not add collection imagery or a running total unless specified.
~~~

### SF adder block

~~~text
CRAFT — SF ADDER
Draw [approved subject] with a clear zone for [increment and unit].
Keep [recipient-directed effect origin] available.
Distinguish it from [collector and multiplier identities].
Leave numeric/operator lettering to the approved text layer.
~~~

### MU / SF multiplier block

~~~text
CRAFT — MULTIPLIER
Draw [approved carrier] around [factor zone].
Keep the factor upright and clear at display size; leave text to the approved layer.
Preserve [active/persistent state cue] and [target effect origin].
Do not invent mathematical machinery, circuitry or a different operation.
~~~

### JP block

~~~text
CRAFT — JP
Use [shared prize construction] for [actual tier name].
Keep family geometry and text position fixed.
Apply [tier accent] and [approved secondary mark/ornament].
Reserve [tier-name/value zone]; do not generate the lettering.
Do not invent extra tiers or four unrelated treasures.
~~~

### WY block

~~~text
CRAFT — CASH-ON-REEL
Draw [approved value carrier] around [text safe rectangle].
Keep that region quiet and unobscured for [longest formatted value].
Preserve [cash/credit/bet-multiple unit] in the text specification, not generated paint.
Do not imply immediate payment or invent a displayed amount.
~~~

### R block — planner first, artist only if visible

~~~text
CRAFT — REPLACEMENT
Confirm whether this identity is visible before resolution.
If it is not visible, reuse target art; request no new illustration.
If visible, draw [approved mystery subject] and prepare [reveal states].
Do not turn an internal replacement code into an arbitrary low-pay object.
~~~

### BL block — planner only

~~~text
CRAFT — BLANK
Preserve the logical blank identity. Generate no illustration.
Use a transparent runtime placeholder only if the delivery contract requires it.
~~~

### Unresolved-role block — planner only

~~~text
CRAFT — UNRESOLVED
Retain the source code and excerpt. Mark the missing role, subject or count unresolved.
Continue known entries. Do not substitute a guessed medium pay or invent assets to close a count.
~~~

## Source register and evidence boundaries

**EVIDENCE — Local audit sources.** The linked legacy guide and Navigator working copy establish what the current guidance/parser says. They do not validate the legacy rules. No source file was changed to produce this specification.

**EVIDENCE — Published game sources.** These support the named mechanics and inspected visual examples only. A provider-authored rules PDF hosted by an operator/CDN is identified as such; it is not represented as a document hosted on the provider's domain.

| Reference | Provenance and inspected scope |
|---|---|
| BOD | Play'n GO's Book of Dead page and published HP1, HP4 and LP1 artwork, visually inspected: framed winged bird, framed Rich Wilde portrait, gold-edged blue 10. |
| BODRULES | Provider-authored GRS0595 Book of Dead rules, dated 14 September 2022, publicly hosted by CNSI CDN; mechanics and code-ranked table. Search-result title incorrectly says Dawn of Egypt; the document identifies Book of Dead. |
| COLLECT / JP assets | Play'n GO's Book of Dead GO Collect page, release 26 February 2026; all four named jackpot images visually inspected. Source assets contain lettering; separate runtime lettering is our proposed workflow. |
| GEMS | Pragmatic Play game-rules/paytable PDF hosted by YesPlay; page 1 visually inspected. Relative pay comparisons use the same count within the same table, not an assumed total-bet conversion. |
| GATES | Pragmatic Play's Gates of Olympus 1000 launch announcement, 14 December 2023; Zeus scatter and multiplier behavior. |
| BASS | Pragmatic Play's Big Bass Bonanza launch description; fisherman wild/collection and fish monetary values. |
| BEAT | H5G's Beat the House release article, May 2020; soundboard bonus trigger and beat-box transformations. |
| GODDESS | H5G-created/IGT rules for Golden Goddess, hosted by Atlantic Lottery; bonus scatter restrictions and Super Stacks. |
| PANTHER | H5G/IGT Shadow of the Panther rules hosted by Loto-Québec, dated November 2019; page 2 visually inspected, mystery replacement rules read. The black rounded rectangles on the paytable page are table layout, not claimed as reel frames. |
| PLATINUM | H5G's Platinum Goddess Jackpot game page; three named progressive tiers. |
| DIVINE | NetEnt's Divine Fortune Gold game page; operation definitions and published collector/adder images visually inspected. |
| MT2 / MT2RULES / MT2PAY | Relax's Money Train 2 page; Danske Spil's published feature rules; Stake's published symbol paytable. Use the platform table only for relative character ordering, not its loosely worded feature summary. |
| REACTOONZ | Play'n GO's Reactoonz game page identifies low-pay creature assets. |
| BLANK | theScore Bet's platform-published IGT Double Diamond rules explicitly refer to blank outcomes. |

**EVIDENCE — Pipeline sources.** Esoteric Software's current Texture Packing and Import PSD documentation supports the narrowly identified technical facts in §7. **UNVERIFIED:** Their example settings are not verified H5G runtime defaults. This document's authoring size, text separation and review workflow are labelled CRAFT choices.

[BOD]: https://www.playngo.com/games/rich-wilde-and-the-book-of-dead
[BODRULES]: https://cnsicdn.kubdev.com/common-content/help/CNSI/game-documents/EN-Book-of-Dead.pdf
[COLLECT]: https://www.playngo.com/games/book-of-dead-go-collect
[JPGRAND]: https://static.wixstatic.com/media/4481fd_6737f0bcd18d499aa01fd9e5454afb64~mv2.png
[JPMAJOR]: https://static.wixstatic.com/media/4481fd_537fcfb5a16548ce8e51c315fa9e68c1~mv2.png
[JPMINOR]: https://static.wixstatic.com/media/4481fd_80393f61fe2f41fa97ee63520ee97309~mv2.png
[JPMINI]: https://static.wixstatic.com/media/4481fd_0fcbdadd2f7b40a9b21f196b83fbc816~mv2.png
[GEMS]: https://yesplay.bet/assets/documents/pragmatic-play-Gems-Bonanza-rules.pdf
[GATES]: https://www.pragmaticplay.com/en/news/zeus-strikes-mighty-multipliers-in-pragmatic-plays-latest-release-gates-of-olympus-1000/
[BASS]: https://www.pragmaticplay.com/en/news/pragmatic-play-turns-fishing-to-spins-in-big-bass-bonanza/
[BEAT]: https://high5games.com/turn-up-the-winning-sound-of-beat-boxes-in-high-5-games-rocking-new-game/
[GODDESS]: https://www.alc.ca/content/dam/alc/images/casino/golden-goddess/Golden%20Goddess%20-%20English.pdf
[PANTHER]: https://assets.lotoquebec.com/ressources/assets/v3/assets/blt8296e79a7001648c/blt68b10d42d9e6fff0/6514428946c10873bed0aded/Shadow-Of-The-Panther_rules_en.pdf
[PLATINUM]: https://high5games.com/games/game/platinum-goddess-jackpot
[DIVINE]: https://games.netent.com/games/divine-fortune-gold
[MT2]: https://www.relax-gaming.com/products/casino/moneytrain2
[MT2RULES]: https://help.danskespil.dk/en/casino-help/slots/relaxmoneytrain2
[MT2PAY]: https://stake.com/casino/games/relax-money-train-2
[REACTOONZ]: https://www.playngo.com/games/reactoonz
[BLANK]: https://thescorebethelp.zendesk.com/hc/en-us/articles/13873577541389-Double-Diamond
[PACK]: https://esotericsoftware.com/spine-texture-packer
[PSD]: https://us.esotericsoftware.com/spine-import-psd
