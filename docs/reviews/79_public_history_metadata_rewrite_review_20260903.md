# Niezależny review Planu 79

Zakres: logiczna wykonalność `docs/plans/79_public_history_metadata_rewrite_20260903.md` przed destrukcyjnym rewrite.
Review nie zawiera nazw ani wartości właścicielskich i nie autoryzuje wykonania operacji.

## Must-fix

### B1 — Backup nie ma jeszcze dowodu odtwarzalności

Samo odszyfrowanie i wylistowanie archiwum jest niewystarczające. Gate 1 musi odtworzyć backup do drugiego katalogu,
uruchomić `git fsck --full`, porównać komplet refów i obiektów z zamrożonym manifestem oraz zweryfikować hashe metadata
i assets każdego Release. Zaszyfrowane archiwum musi mieć zweryfikowaną kopię na odrębnym nośniku; offline recipient
opisuje klucz, nie trwałość samego backupu. Brak kopii Actions artifacts/caches jest nieodwracalnym wyjątkiem i wymaga
jawnego potwierdzenia przed Gate 3, nie tylko wzmianki w rollbacku.

### B2 — Transformacja `git-filter-repo` musi być deterministycznym artefaktem

Plan powinien wymagać przypiętej wersji wraz z hashem źródła/pakietu, użycia `--force` wyłącznie w disposable mirror
oraz zachowania dokładnego bundle'a reguł/callbacków w prywatnym backupie. Reguły muszą osobno obejmować blobs,
filenames/paths, commit messages, tag messages oraz identity fields; replace-text sam nie rozwiązuje wszystkich tych
klas. Po drugim identycznym przebiegu z tego samego mirror manifest nowych refów powinien być identyczny.

### B3 — Owner-only identity i upstream tags wymagają ścisłego manifestu

Zmiana author/committer/tagger może działać wyłącznie dla zamrożonej allowlisty dokładnych owner identities; każdy
niepasujący contributor pozostaje byte-for-byte bez zmian. „Official upstream tag” trzeba klasyfikować przez porównanie
zarówno tag-object ID, jak i peeled target z zamrożonym upstream, nie po samej nazwie. Każdy nienaruszony tag upstream
ma zachować identyczny obiekt. Dla każdego zmienionego annotated/signed tagu manifest musi z góry określić nowy target,
message, tagger i utratę podpisu; nieoczekiwany podpis jest stop condition.

### B4 — Migracja ledger/tag/release nie ma dostatecznie ścisłego kontraktu

Dla każdej pozycji ledger należy zachować upstream SHA, przetłumaczyć owner/local SHA dokładnie przez commit-map,
przeliczyć pole `identity` i zatrzymać operację dla mapowania brakującego, usuniętego lub niejednoznacznego. Trzeba
jawnie ustalić, czy historyczna nazwa release tagu pozostaje bez zmian; jej ref może wskazać wyłącznie commit będący
mapowaniem poprzedniego targetu. Clean-root ledger musi zachować unikalność identity/tag/versionCode oraz ustawić
`next_version_code` ponad maksimum. Test ma objąć lookup istniejącej tożsamości i preview nowej alokacji po rewrite,
nie tylko walidację JSON.

### B5 — Atomic push potrzebuje lease dla każdego z 25 refów

Re-read przed pushem nie zamyka wyścigu. Wymagany jest jeden jawny zestaw 4 branch i 21 tag refspecs, `--atomic` oraz
osobny `--force-with-lease=<ref>:<frozen-old-object>` dla każdego refa. Najpierw trzeba potwierdzić obsługę atomic przez
remote. Bezpośrednio przed pushem należy porównać cały zbiór remote heads/tags, nie tylko wybrane refy; nowy lub
usunięty ref także zatrzymuje operację. `--mirror`, wildcard i bezwarunkowy `--force` pozostają zabronione.

### B6 — CI musi przejść przed nieodwracalnym usunięciem publikacji

Obecna kolejność usuwa Releases/runs/artifacts/caches w Gate 4, a dopiero potem uruchamia CI i release dry-runs w
Gate 5. Należy po fresh-remote scan, ale przed Gate 4, wymagać zielonego CI dla dokładnego rewritten `main` oraz obu
dry-runów. Przed atomic push trzeba zamrozić i sprawdzić stany workflow, zatrzymać/odczekać in-flight runs oraz wyłączyć
tag-triggered publishery. Nie wolno zakładać, że push 21 tagów utworzy zdarzenia tagowe — GitHub nie generuje ich przy
więcej niż trzech tagach w jednym pushu. Nowy run trzeba korelować dokładnym rewritten SHA i zachować jego ID poza
frozen delete set.

### B7 — Usuwanie obiektów GitHub i fresh-clone proof muszą być audytowalne

Kasowanie ma używać wyłącznie zamrożonych numeric IDs, z paginacją, dziennikiem wyniku i ponownym odczytem każdego ID;
404 wolno uznać za sukces dopiero po potwierdzeniu braku obiektu. Po usunięciu Release jego tag musi nadal wskazywać
zatwierdzony rewritten object. Usunięcie runu może kaskadowo usunąć artifact, ale cała zamrożona lista artifacts i
caches nadal wymaga końcowego dowodu nieistnienia. Nowych czystych IDs nie wolno obejmować selektorem licznikowym.

Fresh clone musi pochodzić z publicznego remote do pustego katalogu bez alternates, pobrać wszystkie heads i tags,
porównać dokładny ref manifest, wykonać `fsck`, oba skany wszystkich reachable objects/metadata, porównanie trzech tree
snapshots oraz testy ledger/build/release. Dopiero po tym wolno czyścić lokalne reflogi/helper refs i plaintext
workspace. Closeout musi jasno mówić, że dowiedziono braku osiągalności przez zarządzane branche/tagi, a nie usunięcia
starych obiektów z cudzych klonów, cache lub bezpośrednich historycznych URL.

## Werdykt

**NIE ZATWIERDZAĆ DO DESTRUKCYJNEGO WYKONANIA.** Strategia jest wykonalna, ale B1–B7 muszą zostać wpisane do planu;
szczególnie blokujące są per-ref leases, przesunięcie CI przed nieodwracalne kasowanie oraz pełny restore/fresh-clone
proof.

## Re-review po poprawkach

Ocena wyłącznie zmian w Planie 79:

- **B1 — zamknięty:** dodano dwa nośniki ciphertext, porównanie hashy, pełny restore, `git fsck`, porównanie refów
  i weryfikację hashy Release; brak kopii derived Actions data został jawnie objęty autoryzacją.
- **B2 — zamknięty:** wersja i hash `git-filter-repo` oraz kompletny bundle callbacks są zamrożone, `--force` jest
  ograniczony do disposable mirrors, a dwa niezależne przebiegi muszą dać identyczny manifest refów.
- **B3 — zamknięty:** owner identity wymaga jednocześnie allowlisted original object i dokładnej starej identity;
  upstream tags są klasyfikowane po tag object i peeled target, z jawną obsługą annotated/signed tags.
- **B4 — zamknięty:** ledger ma ścisłe reguły translacji, recompute identity, zachowania tag name/target, unikalności,
  monotoniczności oraz test istniejącego lookup i nowej preview allocation.
- **B5 — zamknięty:** jeden jawny push 25 refów używa `--atomic` i per-ref `--force-with-lease`; pełny zbiór remote
  heads/tags jest ponownie porównywany, a wildcard, `--mirror` i bezwarunkowy force są zabronione.
- **B6 — zamknięty:** workflow są zamrażane, in-flight runs kończone, tag publishers czasowo wyłączane, a CI i oba
  jawnie dispatchowane dry-runs przechodzą przed nieodwracalnym kasowaniem publikacji.
- **B7 — zamknięty:** deletion journal i paginated absence proof są per frozen numeric ID; fresh clone nie używa
  alternates, pobiera wszystkie refy i przechodzi ref/fsck/scan/tree/ledger/build/release proof przed lokalnym cleanupem.

Niewielka niejasność terminologiczna pozostaje między „fresh remote mirror” w Gate 3 a „fresh clone” w Gate 6, do
którego odwołuje się rollback boundary. Nie osłabia to bramek: przed kasowaniem są remote ref/object scans, CI i dwa
dry-runy, a pełny fresh-clone proof jest obowiązkowy przed cleanupem. Warto doprecyzować nazwę w closeoucie.

**Werdykt re-review: ZATWIERDZIĆ DO KONTROLOWANEGO WYKONANIA. B1–B7 są zamknięte; pozostała uwaga jest
nieblokująca.**
