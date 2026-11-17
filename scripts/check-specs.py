"""Check current specification links and acceptance-to-test references."""
import re
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
files = [ROOT / "AGENTS.md", ROOT / "README.md", *sorted((ROOT / "specs").rglob("*.md"))]
errors = []
local_evidence = set()
for path in files:
    for target in re.findall(r"(?<!!)\[[^\]]+\]\(([^)]+)\)", path.read_text()):
        target = target.strip("<>").split("#", 1)[0]
        if not target or "://" in target or target.startswith("mailto:"):
            continue
        resolved = (path.parent / unquote(target)).resolve()
        if not resolved.exists():
            if resolved.is_relative_to(ROOT / "artifacts"):
                local_evidence.add(resolved)
            else:
                errors.append(f"{path.relative_to(ROOT)}: missing link {target}")

mapped = 0
for feature, prefix, suites in [
    ("001-natural-voice-turns", "VT", [("NaturalTurnTests.swift", "PhoneTests.swift", "naturalTurnTestCases()")]),
    ("007-voice-reliability", "VR", [("VoiceReliabilityTests.swift", "PhoneTests.swift", "voiceReliabilityTestCases()")]),
    ("005-conversation-deletion", "CD", [("ConversationDeletionTests.swift", "NativeTests.swift", "conversationDeletionTestCases()")]),
    ("008-conversation-labels", "CL", [("ConversationLabelsTests.swift", "NativeTests.swift", "conversationLabelsTestCases()"), ("ConversationLabelsPhoneTests.swift", "PhoneTests.swift", "conversationLabelsPhoneTestCases()")]),
    ("009-background-conversations", "BG", [("BackgroundConversationTests.swift", "NativeTests.swift", "backgroundConversationTestCases()"), ("BackgroundConversationPhoneTests.swift", "PhoneTests.swift", "backgroundConversationPhoneTestCases()")]),
    ("004-conversation-artwork", "AI", [("ArtworkTests.swift", "NativeTests.swift", "artworkTestCases()")]),
    ("002-lily-pet-behaviors", "PB", [("PetBehaviorTests.swift", "NativeTests.swift", "petBehaviorTestCases()")]),
    ("006-classical-knowledge", "CK", [("ClassicalKnowledgeTests.swift", "NativeTests.swift", "classicalKnowledgeTestCases()"), ("ClassicalKnowledgePhoneTests.swift", "PhoneTests.swift", "classicalKnowledgePhoneTestCases()")]),
]:
    spec = ROOT / f"specs/{feature}/spec.md"
    required = set(re.findall(rf"^\| ({prefix}-\d{{3}}) \|", spec.read_text(), re.MULTILINE))
    tests = "\n".join((ROOT / f"macos/Tests/{test_file}").read_text() for test_file, _, _ in suites)
    covered = set(re.findall(rf'\("({prefix}-\d{{3}}) ', tests))
    if not required:
        errors.append(f"{feature}: specification has no acceptance IDs")
    for identity in sorted(required - covered):
        errors.append(f"{identity}: missing named regression case")
    for identity in sorted(covered - required):
        errors.append(f"{identity}: test is not described by the current specification")
    for test_file, suite, registration in suites:
        if registration not in (ROOT / f"macos/Tests/{suite}").read_text():
            errors.append(f"{test_file}: not registered in {suite}")
        if test_file not in (ROOT / "scripts/macos.mjs").read_text():
            errors.append(f"{test_file}: not compiled by the build script")
    mapped += len(required)
if errors:
    raise SystemExit("\n".join(errors))
print(f"Specs: {len(files)} documents linked; {mapped} acceptance IDs mapped to runnable tests.")
if local_evidence:
    print(f"Local evidence: {len(local_evidence)} untracked artifact paths are absent; historical results were not revalidated.")
