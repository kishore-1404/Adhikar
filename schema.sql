-- ============================================================================
-- ADHIKAR — LEGAL LITERACY PLATFORM
-- PostgreSQL schema + seed data
-- ============================================================================
-- This schema is the source of truth for the platform. The index.html app
-- embeds the same seed data directly for static deployment; when you wire up
-- a backend, point it at this schema and remove the embedded JS constants.
--
-- Target: PostgreSQL 15+. Extensions used: uuid-ossp, pgcrypto, btree_gin.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "btree_gin";

-- ============================================================================
-- 1. REFERENCE / CORE TABLES
-- ============================================================================

-- Acts (source statutes, rules, regulations)
CREATE TABLE IF NOT EXISTS acts (
    id            TEXT PRIMARY KEY,          -- e.g. 'crpc', 'constitution', 'posh-2013'
    short_name    TEXT NOT NULL,             -- 'CrPC'
    full_name     TEXT NOT NULL,             -- 'Code of Criminal Procedure, 1973'
    year          INT,
    jurisdiction  TEXT NOT NULL DEFAULT 'IN-CENTRAL',  -- or IN-<STATE_CODE>
    category      TEXT,                      -- 'criminal', 'constitution', 'consumer', ...
    official_url  TEXT,
    last_amended  DATE,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Individual sections / articles / rules
CREATE TABLE IF NOT EXISTS law_sections (
    id            TEXT PRIMARY KEY,          -- e.g. 'crpc-41', 'art-21'
    act_id        TEXT NOT NULL REFERENCES acts(id) ON DELETE RESTRICT,
    number        TEXT NOT NULL,             -- '41', 'Art. 21', 'S. 4'
    title         TEXT NOT NULL,
    raw_text      TEXT,                      -- the original statutory text (optional)
    simplified    TEXT NOT NULL,             -- plain-language version (8th-grade reading)
    source_cite   TEXT NOT NULL,             -- authoritative citation string
    reviewer_id   UUID,                      -- FK to users(id), null if seed data
    reviewed_at   TIMESTAMPTZ,
    language      TEXT NOT NULL DEFAULT 'en',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_law_sections_act ON law_sections(act_id);

-- Case-law / reference links attached to a section (D.K. Basu, Arnesh Kumar, etc.)
CREATE TABLE IF NOT EXISTS section_references (
    id            BIGSERIAL PRIMARY KEY,
    section_id    TEXT NOT NULL REFERENCES law_sections(id) ON DELETE CASCADE,
    kind          TEXT NOT NULL,             -- 'case', 'amendment', 'circular', 'guideline'
    title         TEXT NOT NULL,             -- 'D.K. Basu v. State of West Bengal (1997)'
    citation      TEXT,                      -- '(1997) 1 SCC 416'
    summary       TEXT,
    url           TEXT
);

CREATE INDEX idx_section_refs ON section_references(section_id);

-- ============================================================================
-- 2. SCENARIOS (the core learning unit)
-- ============================================================================

CREATE TYPE scenario_status AS ENUM ('draft', 'pre_check', 'tier1_review', 'tier2_review', 'published', 'archived');

CREATE TABLE IF NOT EXISTS scenarios (
    id            TEXT PRIMARY KEY,          -- e.g. 's1', 's-uuid-...'
    domain        TEXT NOT NULL,             -- 'police' | 'workplace' | 'consumer' | 'housing' | 'cyber' | 'education'
    difficulty    SMALLINT NOT NULL CHECK (difficulty BETWEEN 1 AND 3),
    title         TEXT NOT NULL,
    situation     TEXT NOT NULL,             -- the scenario prompt
    concept       TEXT NOT NULL,             -- short name of the legal concept being tested
    language      TEXT NOT NULL DEFAULT 'en',
    status        scenario_status NOT NULL DEFAULT 'published',
    source        TEXT NOT NULL DEFAULT 'seed',   -- 'seed' | 'ai_drafted' | 'community'
    author_id     UUID,                      -- null for seed
    tier1_reviewer UUID,
    tier2_reviewer UUID,
    published_at  TIMESTAMPTZ,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_scenarios_domain_diff ON scenarios(domain, difficulty) WHERE status = 'published';
CREATE INDEX idx_scenarios_status ON scenarios(status);

-- 4 choices per scenario (MCQ format)
CREATE TABLE IF NOT EXISTS scenario_choices (
    id            BIGSERIAL PRIMARY KEY,
    scenario_id   TEXT NOT NULL REFERENCES scenarios(id) ON DELETE CASCADE,
    choice_code   CHAR(1) NOT NULL,          -- 'a', 'b', 'c', 'd'
    text          TEXT NOT NULL,
    is_correct    BOOLEAN NOT NULL,
    explanation   TEXT NOT NULL,
    UNIQUE (scenario_id, choice_code)
);

-- Each scenario can cite multiple law sections
CREATE TABLE IF NOT EXISTS scenario_law_links (
    scenario_id   TEXT NOT NULL REFERENCES scenarios(id) ON DELETE CASCADE,
    section_id    TEXT NOT NULL REFERENCES law_sections(id) ON DELETE RESTRICT,
    relevance     TEXT NOT NULL DEFAULT 'primary',   -- 'primary' | 'supporting'
    PRIMARY KEY (scenario_id, section_id)
);

-- Exactly one correct answer per scenario — enforce via partial unique index
CREATE UNIQUE INDEX one_correct_per_scenario
    ON scenario_choices (scenario_id)
    WHERE is_correct = TRUE;

-- ============================================================================
-- 3. ACT GUIDES (situation-first emergency references)
-- ============================================================================

CREATE TABLE IF NOT EXISTS act_guides (
    id            TEXT PRIMARY KEY,          -- 'police-at-door', ...
    title         TEXT NOT NULL,
    icon          TEXT,
    color         TEXT,
    language      TEXT NOT NULL DEFAULT 'en',
    reviewer_id   UUID,
    reviewed_at   TIMESTAMPTZ,
    published     BOOLEAN NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS act_guide_items (
    id            BIGSERIAL PRIMARY KEY,
    guide_id      TEXT NOT NULL REFERENCES act_guides(id) ON DELETE CASCADE,
    bucket        TEXT NOT NULL,             -- 'must_know' | 'can_say' | 'document' | 'call_first'
    ord           INT NOT NULL,
    content       TEXT NOT NULL
);

CREATE INDEX idx_guide_items ON act_guide_items(guide_id, bucket, ord);

-- ============================================================================
-- 4. USERS & LEARNING STATE
-- ============================================================================

CREATE TABLE IF NOT EXISTS user_profiles (
    id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    phone_hash        TEXT UNIQUE,           -- store hash of phone, never raw
    anon_id           TEXT UNIQUE,           -- for anonymous / device-only users
    preferred_language TEXT NOT NULL DEFAULT 'en',
    literacy_level    SMALLINT NOT NULL DEFAULT 1 CHECK (literacy_level BETWEEN 1 AND 3),
    daily_goal_min    SMALLINT NOT NULL DEFAULT 10,
    streak            INT NOT NULL DEFAULT 0,
    last_active_date  DATE,
    interests         TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
    onboarding_done   BOOLEAN NOT NULL DEFAULT FALSE
);

-- Partitioned by month for scale — attempts dwarf every other table
CREATE TABLE IF NOT EXISTS user_attempts (
    id                BIGSERIAL,
    user_id           UUID NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
    scenario_id       TEXT NOT NULL REFERENCES scenarios(id) ON DELETE RESTRICT,
    chosen_code       CHAR(1) NOT NULL,
    is_correct        BOOLEAN NOT NULL,
    response_ms       INT NOT NULL,
    client_ts         TIMESTAMPTZ NOT NULL,
    server_ts         TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (id, server_ts)
) PARTITION BY RANGE (server_ts);

-- Create a default partition so INSERTs work out of the box; add monthly partitions in ops
CREATE TABLE IF NOT EXISTS user_attempts_default PARTITION OF user_attempts DEFAULT;
CREATE INDEX idx_attempts_user ON user_attempts (user_id, server_ts DESC);
CREATE INDEX idx_attempts_scenario ON user_attempts (scenario_id);

-- SM-2 spaced repetition state per (user, scenario)
CREATE TABLE IF NOT EXISTS user_revision_schedule (
    user_id         UUID NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
    scenario_id     TEXT NOT NULL REFERENCES scenarios(id) ON DELETE RESTRICT,
    ease_factor     NUMERIC(4,2) NOT NULL DEFAULT 2.50,
    repetitions     INT NOT NULL DEFAULT 0,
    interval_days   INT NOT NULL DEFAULT 0,
    next_due        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, scenario_id)
);

CREATE INDEX idx_schedule_due ON user_revision_schedule (user_id, next_due);

-- Bookmarks — user-saved scenarios
CREATE TABLE IF NOT EXISTS user_bookmarks (
    user_id         UUID NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
    scenario_id     TEXT NOT NULL REFERENCES scenarios(id) ON DELETE CASCADE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, scenario_id)
);

-- ============================================================================
-- 5. CONTRIBUTIONS & MODERATION
-- ============================================================================

CREATE TYPE contribution_type AS ENUM ('scenario', 'simplification', 'correction', 'translation');
CREATE TYPE contribution_status AS ENUM ('pending', 'approved', 'approved_with_edits', 'rejected', 'escalated');

CREATE TABLE IF NOT EXISTS contributions (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    contributor_id  UUID REFERENCES user_profiles(id) ON DELETE SET NULL,
    type            contribution_type NOT NULL,
    domain          TEXT,
    title           TEXT NOT NULL,
    payload         JSONB NOT NULL,            -- full submission (scenario / proposed text / etc.)
    auto_checks     JSONB NOT NULL DEFAULT '{}'::jsonb,
                                               -- { schema, citationExists, contradiction, duplicate, difficulty }
    flagged_codes   TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],    -- R1..R6 rejection codes
    suggested_tier  TEXT,                      -- 'Tier 1' | 'Tier 2'
    status          contribution_status NOT NULL DEFAULT 'pending',
    reviewer_id     UUID,
    reviewer_note   TEXT,
    decided_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_contrib_status ON contributions(status);
CREATE INDEX idx_contrib_flags ON contributions USING GIN (flagged_codes);

-- Reviewer audit log
CREATE TABLE IF NOT EXISTS review_decisions (
    id              BIGSERIAL PRIMARY KEY,
    contribution_id UUID NOT NULL REFERENCES contributions(id) ON DELETE CASCADE,
    reviewer_id     UUID NOT NULL,
    decision        contribution_status NOT NULL,
    note            TEXT,
    codes           TEXT[],
    decided_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Contributor reputation (influences routing — high rep = less aggressive checks)
CREATE TABLE IF NOT EXISTS contributor_reputation (
    user_id         UUID PRIMARY KEY REFERENCES user_profiles(id) ON DELETE CASCADE,
    score           INT NOT NULL DEFAULT 0,
    approved_count  INT NOT NULL DEFAULT 0,
    rejected_count  INT NOT NULL DEFAULT 0,
    last_updated    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================================
-- 6. UPDATED_AT TRIGGER HELPER
-- ============================================================================

CREATE OR REPLACE FUNCTION set_updated_at() RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_law_sections_updated BEFORE UPDATE ON law_sections
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_scenarios_updated BEFORE UPDATE ON scenarios
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_act_guides_updated BEFORE UPDATE ON act_guides
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_schedule_updated BEFORE UPDATE ON user_revision_schedule
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================================
-- 7. SEED DATA — ACTS
-- ============================================================================

INSERT INTO acts (id, short_name, full_name, year, category, jurisdiction) VALUES
    ('crpc',         'CrPC',                    'Code of Criminal Procedure, 1973',                      1973, 'criminal',     'IN-CENTRAL'),
    ('constitution', 'Constitution',            'Constitution of India',                                 1950, 'constitution', 'IN-CENTRAL'),
    ('posh-2013',    'POSH Act',                'Sexual Harassment of Women at Workplace (Prevention, Prohibition and Redressal) Act, 2013', 2013, 'labour', 'IN-CENTRAL'),
    ('mat-1961',     'Maternity Benefit Act',   'Maternity Benefit Act, 1961',                           1961, 'labour',       'IN-CENTRAL'),
    ('cpa-2019',     'Consumer Protection Act', 'Consumer Protection Act, 2019',                         2019, 'consumer',     'IN-CENTRAL'),
    ('cpa-ec-2020',  'CPA E-Commerce Rules',    'Consumer Protection (E-Commerce) Rules, 2020',          2020, 'consumer',     'IN-CENTRAL'),
    ('it-2000',      'IT Act',                  'Information Technology Act, 2000',                      2000, 'cyber',        'IN-CENTRAL'),
    ('rte-2009',     'RTE Act',                 'Right of Children to Free and Compulsory Education Act, 2009', 2009, 'education', 'IN-CENTRAL'),
    ('ugc-ragging',  'UGC Regulations',         'UGC Regulations on Curbing the Menace of Ragging in Higher Educational Institutions, 2009', 2009, 'education', 'IN-CENTRAL'),
    ('tpa-1882',     'Transfer of Property Act','Transfer of Property Act, 1882',                        1882, 'property',     'IN-CENTRAL'),
    ('sra-1963',     'Specific Relief Act',     'Specific Relief Act, 1963',                             1963, 'civil',        'IN-CENTRAL')
ON CONFLICT (id) DO NOTHING;

-- ============================================================================
-- 8. SEED DATA — LAW SECTIONS
-- ============================================================================

INSERT INTO law_sections (id, act_id, number, title, simplified, source_cite) VALUES
    ('crpc-41',   'crpc',         '41',       'When police may arrest without warrant',
     'A police officer can arrest without a warrant only in specific situations — typically for cognizable offences (serious crimes) with reasonable grounds. For offences punishable with up to 7 years, the officer must record reasons.',
     'Section 41, Code of Criminal Procedure, 1973'),
    ('crpc-41a',  'crpc',         '41A',      'Notice of appearance before police officer',
     'For offences where arrest is not required (generally punishable up to 7 years), police must issue a written notice to appear, rather than making an immediate arrest. Arrest follows only on failure to comply.',
     'Section 41A, CrPC (post-Arnesh Kumar v. State of Bihar, 2014)'),
    ('crpc-46-4', 'crpc',         '46(4)',    'Arrest of women — time restriction',
     'A woman should not be arrested after sunset and before sunrise, except in exceptional circumstances with prior written permission of a Judicial Magistrate. The arrest should ordinarily be made by a woman police officer.',
     'Section 46(4), CrPC'),
    ('crpc-50',   'crpc',         '50(1)',    'Right to know grounds of arrest',
     'A person arrested without a warrant must be informed, as soon as possible, of the grounds of arrest. For bailable offences, they must also be informed of the right to bail.',
     'Section 50, CrPC; Article 22(1), Constitution of India'),
    ('crpc-50a',  'crpc',         '50A',      'Right to inform a relative of arrest',
     'Police must inform a nominated relative or friend of the person''s arrest and the place of detention. This right attaches from the moment of arrest.',
     'Section 50A, CrPC; D.K. Basu v. State of West Bengal (1997)'),
    ('crpc-100',  'crpc',         '100',      'Persons in charge of closed place to allow search',
     'A search must generally be conducted in the presence of at least two independent local witnesses. The person searched has the right to a list of items seized, signed by the witnesses.',
     'Section 100, CrPC'),
    ('crpc-165',  'crpc',         '165',      'Search by police officer',
     'Police can search without a warrant only where they have reasonable grounds to believe a thing necessary for investigation may be found, and they must record reasons in writing before the search.',
     'Section 165, CrPC'),
    ('art-20-3',  'constitution', 'Art. 20(3)','Right against self-incrimination',
     'No person accused of an offence can be compelled to be a witness against themselves. You cannot be forced to confess or give testimony that incriminates you.',
     'Article 20(3), Constitution of India'),
    ('art-21',    'constitution', 'Art. 21',  'Right to life and personal liberty',
     'No person shall be deprived of life or personal liberty except according to procedure established by law — and that procedure must be fair, just, and reasonable.',
     'Article 21, Constitution of India; Maneka Gandhi v. Union of India (1978)'),
    ('art-22-1',  'constitution', 'Art. 22(1)','Rights on arrest',
     'Every person arrested has the right to be informed of the grounds of arrest and the right to consult and be defended by a lawyer of their choice.',
     'Article 22(1), Constitution of India'),
    ('art-22-2',  'constitution', 'Art. 22(2)','Production before magistrate',
     'Every person arrested must be produced before a magistrate within 24 hours of arrest, excluding travel time. Detention beyond 24 hours requires the magistrate''s order.',
     'Article 22(2), Constitution of India'),
    ('art-19-1-b','constitution', 'Art. 19(1)(b)','Right to assemble peaceably',
     'All citizens have the right to assemble peaceably and without arms. This right is subject to reasonable restrictions in the interest of public order and sovereignty.',
     'Article 19(1)(b), Constitution of India'),
    ('posh-4',    'posh-2013',    'S. 4',     'Internal Complaints Committee',
     'Every employer with 10 or more employees must constitute an Internal Complaints Committee (ICC) at each workplace location to receive and inquire into sexual harassment complaints.',
     'Section 4, POSH Act, 2013'),
    ('posh-9',    'posh-2013',    'S. 9',     'Complaint timeline',
     'A complaint of sexual harassment should be filed within three months of the incident (or the last of a series of incidents). The ICC can extend this by up to three more months in writing if satisfied that circumstances prevented timely filing.',
     'Section 9, POSH Act, 2013'),
    ('mat-12',    'mat-1961',     'S. 12',    'Dismissal during pregnancy',
     'A woman absent on maternity leave cannot be dismissed, and any dismissal during pregnancy or leave that deprives her of maternity benefits is unlawful.',
     'Section 12, Maternity Benefit Act, 1961'),
    ('cpa-2-47',  'cpa-2019',     'S. 2(47)', 'Unfair trade practice',
     'Misleading the consumer about quality, quantity, or performance, or withholding material information, is an unfair trade practice and actionable under consumer law.',
     'Section 2(47), Consumer Protection Act, 2019'),
    ('cpa-ec-4',  'cpa-ec-2020',  'Rule 4',   'Duties of e-commerce entities',
     'E-commerce entities must display seller information, provide a clear return and refund policy, and cannot manipulate prices or impose conditions that are unfair to consumers. Platforms are liable for the products listed.',
     'Rule 4, Consumer Protection (E-Commerce) Rules, 2020'),
    ('it-66c',    'it-2000',      'S. 66C',   'Identity theft',
     'Dishonestly or fraudulently using another person''s electronic signature, password, or any other unique identification is punishable with imprisonment up to 3 years and fine up to ₹1 lakh.',
     'Section 66C, Information Technology Act, 2000'),
    ('it-66d',    'it-2000',      'S. 66D',   'Cheating by personation using computer',
     'Cheating by impersonation using a computer resource or communication device is punishable with imprisonment up to 3 years and fine up to ₹1 lakh.',
     'Section 66D, IT Act, 2000'),
    ('it-66e',    'it-2000',      'S. 66E',   'Violation of privacy',
     'Capturing, publishing or transmitting a private image of another person without consent — under circumstances violating their privacy — is punishable with imprisonment up to 3 years and fine up to ₹2 lakh.',
     'Section 66E, IT Act, 2000'),
    ('it-67',     'it-2000',      'S. 67',    'Obscene content',
     'Publishing or transmitting obscene material in electronic form is a criminal offence, punishable on first conviction with imprisonment up to 3 years and fine up to ₹5 lakh.',
     'Section 67, IT Act, 2000'),
    ('rte-12',    'rte-2009',     'S. 12(1)(c)','Private school reservation',
     'Private unaided schools must admit at least 25% of their entry-level class from children of economically weaker sections and disadvantaged groups in the neighborhood, and provide free education until Class 8.',
     'Section 12(1)(c), Right of Children to Free and Compulsory Education Act, 2009'),
    ('ugc-ragging','ugc-ragging', '2009',     'Prohibition of ragging',
     'Ragging in any form — physical, verbal, psychological — is prohibited in all higher educational institutions. Institutions must have anti-ragging committees and squads. Offenders face penalties up to expulsion and criminal prosecution.',
     'UGC Regulations on Curbing the Menace of Ragging in Higher Educational Institutions, 2009'),
    ('tpa-106',   'tpa-1882',     'S. 106',   'Notice to quit',
     'In the absence of a contract or local law, a month-to-month tenancy can be terminated only by 15 days'' written notice. Eviction cannot be by force — it requires legal process.',
     'Section 106, Transfer of Property Act, 1882'),
    ('sra-6',     'sra-1963',     'S. 6',     'Recovery of possession',
     'A person dispossessed of immovable property without their consent, otherwise than by due course of law, may recover possession through a suit filed within 6 months. No one can be evicted by force.',
     'Section 6, Specific Relief Act, 1963')
ON CONFLICT (id) DO NOTHING;

-- ============================================================================
-- 9. SEED DATA — CASE / REFERENCE LINKS
-- ============================================================================

INSERT INTO section_references (section_id, kind, title, citation, summary) VALUES
    ('crpc-50a', 'case', 'D.K. Basu v. State of West Bengal',       '(1997) 1 SCC 416',  'Laid down mandatory guidelines for arrest and detention, including right to inform a relative.'),
    ('crpc-41a', 'case', 'Arnesh Kumar v. State of Bihar',          '(2014) 8 SCC 273',  'Held arrest should not be automatic for offences up to 7 years; notice under §41A CrPC must be issued first.'),
    ('art-21',   'case', 'Maneka Gandhi v. Union of India',         '(1978) 1 SCC 248',  'Procedure under Art. 21 must be fair, just and reasonable — not merely any procedure.'),
    ('rte-12',   'case', 'Society for Unaided Private Schools v. Union of India', '(2012) 6 SCC 1', 'Upheld the constitutional validity of §12(1)(c) RTE Act.'),
    ('cpa-2-47', 'case', 'Indian Medical Association v. V.P. Shantha', '(1995) 6 SCC 651', 'Paid medical services fall within the definition of "service" under consumer protection law.'),
    ('ugc-ragging','case','Vishwa Jagriti Mission v. Central Government','(2001) 6 SCC 577', 'Directed framework to curb ragging in educational institutions.');

-- ============================================================================
-- 10. SEED DATA — SCENARIOS
-- ============================================================================
-- Format: 20 scenarios mirroring the HTML app. Each has 4 choices and 1..N law links.

INSERT INTO scenarios (id, domain, difficulty, title, situation, concept, status, source) VALUES
    ('s1',  'police',    2, 'Arrest at your door',
     'Two police officers come to your home at 11 PM. They say they are arresting your brother in connection with a theft nearby. Your brother asks why he is being arrested.',
     'Right to know grounds of arrest', 'published', 'seed'),
    ('s2',  'police',    2, 'Informing family after arrest',
     'You are arrested at a protest. You ask to call your parents to tell them where you are. The officer says "no calls allowed from the station."',
     'Right to inform on arrest', 'published', 'seed'),
    ('s3',  'police',    3, 'Station "questioning" invitation',
     'A police officer visits your office and says "come with us to the station for questioning in a cheating case." The offence is punishable with up to 3 years in prison.',
     'Notice vs. arrest (minor offences)', 'published', 'seed'),
    ('s4',  'police',    3, 'Search of your home',
     'A police officer wants to search your home. They have no warrant. When asked, they say "we don''t need one — we''re the police."',
     'Search procedure safeguards', 'published', 'seed'),
    ('s5',  'police',    3, 'Evening arrest of a woman',
     'Police officers arrive at a woman''s home at 8 PM wanting to arrest her for a minor offence. Only male officers are present.',
     'Arrest safeguards for women', 'published', 'seed'),
    ('s6',  'workplace', 2, 'Workplace harassment — where to complain',
     'You work at a private company with 30 employees. A senior colleague repeatedly makes unwelcome comments about your appearance. You want to file a formal complaint.',
     'Internal Complaints Committee', 'published', 'seed'),
    ('s7',  'workplace', 3, 'Missed the 3-month POSH deadline',
     'An incident of workplace sexual harassment happened 4 months ago. You weren''t ready to complain earlier. A friend says it''s now too late.',
     'POSH complaint timelines', 'published', 'seed'),
    ('s8',  'workplace', 3, 'Termination during pregnancy',
     'You inform your employer you are pregnant. Your manager says "we''ll terminate you before your leave starts to avoid paying maternity benefits."',
     'Maternity rights — protection from dismissal', 'published', 'seed'),
    ('s9',  'consumer',  1, 'Damaged product from online seller',
     'You bought a phone online. It arrived with a cracked screen — clearly damaged before delivery. The seller replies "no returns" and refuses.',
     'Defective goods — consumer remedies', 'published', 'seed'),
    ('s10', 'consumer',  2, 'E-commerce platform blames delivery partner',
     'An e-commerce seller sends you a different product than what you ordered. They refuse replacement, saying the issue is with the delivery partner.',
     'E-commerce platform accountability', 'published', 'seed'),
    ('s11', 'cyber',     2, 'Fake profile impersonating you',
     'Someone has created a fake social media profile using your photos and name, and is messaging your contacts asking for money.',
     'Online identity theft', 'published', 'seed'),
    ('s12', 'cyber',     3, 'Threat to share private photos',
     'Your ex-partner threatens to share private photos of you online unless you meet them.',
     'Image-based abuse and criminal intimidation', 'published', 'seed'),
    ('s13', 'housing',   2, 'Late-night eviction attempt',
     'Your landlord arrives at 10 PM with an oral notice to vacate by morning. They have two people ready to physically remove your belongings.',
     'Protection against forcible eviction', 'published', 'seed'),
    ('s14', 'education', 2, 'Private school refuses admission',
     'A private unaided school refuses admission to your 7-year-old child, saying they don''t take students from outside their preferred area.',
     'Right to education — reservation in private schools', 'published', 'seed'),
    ('s15', 'education', 2, 'Ragging dismissed as "fun"',
     'Senior students in your college hostel force new students to do embarrassing acts. The warden says "boys will be boys, it''s just fun."',
     'Anti-ragging law', 'published', 'seed'),
    ('s16', 'police',    3, 'Asked to sign a confession',
     'You are being interrogated. An officer asks you to sign a confession statement. No lawyer is present.',
     'Right against self-incrimination', 'published', 'seed'),
    ('s17', 'police',    2, 'The 24-hour rule',
     'Your friend was arrested 30 hours ago. They have not been produced before a magistrate. The family is told they''ll be produced "whenever convenient."',
     'Production before magistrate within 24 hours', 'published', 'seed'),
    ('s18', 'consumer',  3, 'Undisclosed hospital charges',
     'A private hospital charges you ₹50,000 extra for services that were never disclosed in the pre-admission estimate.',
     'Medical services under consumer law', 'published', 'seed'),
    ('s19', 'housing',   2, 'Security deposit withheld',
     'Your rental ended. You returned the flat in good condition. Your landlord refuses to return the security deposit, saying "the paint is not fresh enough."',
     'Security deposit — return obligations', 'published', 'seed'),
    ('s20', 'cyber',     2, 'Morphed obscene image',
     'Someone morphs your face onto an obscene image and circulates it in a WhatsApp group.',
     'Online image-based abuse', 'published', 'seed')
ON CONFLICT (id) DO NOTHING;

-- --- Scenario choices (4 per scenario) ------------------------------------
-- Each row uses a short alias; only correct row per scenario has is_correct=true.

INSERT INTO scenario_choices (scenario_id, choice_code, text, is_correct, explanation) VALUES
    -- s1
    ('s1','a','The police don''t need to tell him anything — he must go silently.', false,
     'Incorrect. Section 50(1) CrPC and Article 22(1) of the Constitution require police to inform every arrested person of the grounds of arrest as soon as possible.'),
    ('s1','b','Police must tell him the reason for his arrest.', true,
     'Correct. Both CrPC §50(1) and Article 22(1) guarantee every arrested person the right to be informed of the grounds of arrest. This is a non-negotiable safeguard.'),
    ('s1','c','A warrant is required for every arrest, no exceptions.', false,
     'Incorrect. For cognizable offences like theft, CrPC §41 allows arrest without a warrant if the officer has reasonable grounds.'),
    ('s1','d','Nobody can be arrested at night under any circumstance.', false,
     'Incorrect. There is no general bar on night arrests. For women, §46(4) restricts post-sunset arrests, but no blanket rule applies to all persons.'),
    -- s2
    ('s2','a','The officer is correct — no calls allowed after arrest.', false,
     'Incorrect. This contradicts §50A CrPC and the D.K. Basu guidelines which guarantee the right to have a relative/friend informed.'),
    ('s2','b','You have a right to have one relative or friend informed of your arrest and place of detention.', true,
     'Correct. §50A CrPC obligates police to inform a nominated person of your arrest. The D.K. Basu guidelines (1997) reinforced this.'),
    ('s2','c','You can only call a lawyer, not family.', false,
     'Incorrect. Both rights co-exist: Article 22(1) gives the right to a lawyer, and §50A gives the right to inform a relative/friend.'),
    ('s2','d','You can call only after being produced before a magistrate.', false,
     'Incorrect. The right attaches at the time of arrest, not after magistrate production.'),
    -- s3
    ('s3','a','You must go immediately — refusal is a crime.', false,
     'Incorrect. The Supreme Court in Arnesh Kumar (2014) emphasized that for offences punishable up to 7 years, arrest is not automatic.'),
    ('s3','b','Police can issue a written notice under §41A CrPC requiring you to appear; immediate arrest is generally not justified for this offence class.', true,
     'Correct. Post-Arnesh Kumar, §41A CrPC requires a notice of appearance for offences up to 7 years, with arrest only on failure to comply.'),
    ('s3','c','The officer can force you only if they use handcuffs.', false,
     'Incorrect. Handcuffing is not a legal requirement or license for arrest. The Prem Shankar Shukla case holds handcuffing to be ordinarily impermissible.'),
    ('s3','d','You must have a lawyer present before anything can happen.', false,
     'Incorrect. A lawyer cannot be present during interrogation itself (only within visible distance per D.K. Basu), but you have the right to consult a lawyer.'),
    -- s4
    ('s4','a','Police can search any place at any time without a warrant.', false,
     'Incorrect. Searches require either a warrant, or §165 CrPC procedure (recorded reasons in writing, urgency).'),
    ('s4','b','Warrantless search is allowed only in limited situations, requires recorded reasons, and needs two independent local witnesses.', true,
     'Correct. §165 CrPC allows warrantless search only on reasonable grounds with written reasons. §100 CrPC requires two independent local witnesses.'),
    ('s4','c','Police need a warrant only for searches between 10 PM and 6 AM.', false,
     'Incorrect. The time of day is not the primary test; the legal basis is.'),
    ('s4','d','If you object, the police cannot search at all.', false,
     'Incorrect. You cannot necessarily prevent a lawful search, but procedure must be followed. Your recourse is to insist on witnesses and to document violations.'),
    -- s5
    ('s5','a','Male officers can arrest women at any time.', false,
     'Incorrect. §46(4) CrPC restricts post-sunset arrests of women and requires arrest ordinarily by a woman officer.'),
    ('s5','b','A woman should generally not be arrested after sunset and before sunrise, except with prior written permission of a Judicial Magistrate. Arrest should ordinarily be by a woman officer.', true,
     'Correct. §46(4) CrPC safeguard; D.K. Basu guidelines also reinforce this.'),
    ('s5','c','A woman can only be arrested at a police station, not at home.', false,
     'Incorrect. There is no such rule; the restriction is on timing and mode.'),
    ('s5','d','A female family member must be present for every arrest of a woman.', false,
     'Incorrect. Not a blanket requirement. The primary safeguards are time-of-day and woman officer.'),
    -- s6
    ('s6','a','You must go to the police first — companies don''t handle this.', false,
     'Incorrect. The POSH Act provides a dedicated internal mechanism. Police complaint is a separate option, not a prerequisite.'),
    ('s6','b','Your company must have an Internal Complaints Committee (ICC) where you can file a written complaint.', true,
     'Correct. POSH Act §4 mandates an ICC at every workplace with 10+ employees. §9 governs how complaints are filed.'),
    ('s6','c','You can complain only if the harasser is a man.', false,
     'Incorrect. The POSH Act does not restrict by gender of the respondent; the Act''s protections apply regardless.'),
    ('s6','d','You must resign before filing.', false,
     'Incorrect. The law protects employees during and after such complaints; resignation is not required.'),
    -- s7
    ('s7','a','Your friend is right — the 3-month deadline has expired.', false,
     'Incorrect. The deadline is extendable — §9 proviso allows up to 3 additional months.'),
    ('s7','b','The ICC can extend the deadline by up to 3 more months if you explain why you couldn''t file earlier.', true,
     'Correct. §9 proviso of POSH Act permits an extension of up to 3 further months for reasons to be recorded in writing.'),
    ('s7','c','You can file any time — there is no deadline.', false,
     'Incorrect. There is a statutory time frame, though extendable.'),
    ('s7','d','You must go straight to court since the ICC period is over.', false,
     'Incorrect. The extension route exists within the ICC framework.'),
    -- s8
    ('s8','a','Employers can terminate for any reason with notice.', false,
     'Incorrect. §12 of the Maternity Benefit Act specifically prohibits dismissal that deprives a woman of maternity benefits.'),
    ('s8','b','Terminating a woman during pregnancy in a way that deprives her of maternity benefits is expressly prohibited and challengeable.', true,
     'Correct. §12 Maternity Benefit Act, 1961 prohibits such dismissal.'),
    ('s8','c','Maternity benefits only apply to government employees.', false,
     'Incorrect. The Act covers most establishments employing 10+ employees, including private sector.'),
    ('s8','d','Only women employed over 5 years qualify.', false,
     'Incorrect. The eligibility threshold is 80 days of work in the 12 months preceding the expected date of delivery.'),
    -- s9
    ('s9','a','"No returns" policy is binding — you must keep it.', false,
     'Incorrect. A blanket "no returns" policy cannot override statutory consumer rights under the CPA 2019 and E-Commerce Rules.'),
    ('s9','b','You have a right to a refund, replacement, or repair; blanket no-return policies cannot override statutory rights.', true,
     'Correct. CPA 2019 and the E-Commerce Rules, 2020 (Rule 4) require platforms to have fair return/refund processes and treat defective delivery as an unfair trade practice.'),
    ('s9','c','You can complain only if damage exceeds ₹10,000.', false,
     'Incorrect. There is no such threshold for consumer rights. Value only affects which commission hears the dispute.'),
    ('s9','d','Online purchases have no consumer protection.', false,
     'Incorrect. The Consumer Protection (E-Commerce) Rules, 2020 specifically govern online commerce.'),
    -- s10
    ('s10','a','It''s the delivery partner''s fault — sort it out with them.', false,
     'Incorrect. Platforms cannot escape liability by blaming intermediaries they engaged.'),
    ('s10','b','The e-commerce entity has duties under the E-Commerce Rules and cannot deny replacement based on who the seller or delivery partner is.', true,
     'Correct. Rule 4 of the Consumer Protection (E-Commerce) Rules, 2020 places clear accountability on e-commerce entities.'),
    ('s10','c','You can complain only if you paid by card, not UPI.', false,
     'Incorrect. Payment mode is irrelevant to consumer rights.'),
    ('s10','d','You need a police report first.', false,
     'Incorrect. A police report is not a prerequisite to consumer remedies.'),
    -- s11
    ('s11','a','Platforms don''t act on these — nothing you can do.', false,
     'Incorrect. Platforms have grievance officers under the IT Rules 2021 and must respond to such reports.'),
    ('s11','b','This is identity theft and cheating by personation; file on cybercrime.gov.in and with local police, and report to the platform.', true,
     'Correct. IT Act §66C (identity theft) and §66D (cheating by personation via computer resource) apply. IPC §419 and §420 may also apply.'),
    ('s11','c','You must first find out who the impostor is.', false,
     'Incorrect. Investigation is the police''s job. You just need to report.'),
    ('s11','d','It''s only a crime if money was actually taken.', false,
     'Incorrect. Identity misuse and impersonation are offences in themselves, independent of whether money was stolen.'),
    -- s12
    ('s12','a','It''s not a crime unless they actually share the photos.', false,
     'Incorrect. The threat itself is a criminal offence. Waiting lets the harm compound.'),
    ('s12','b','Both the threat and sharing such images are criminal offences; you can file a complaint immediately.', true,
     'Correct. IT Act §66E (privacy violation), §67/§67A (obscene/sexually explicit content), IPC §354C (voyeurism), §506 (criminal intimidation) all apply.'),
    ('s12','c','Police can''t act because the photos have not yet been shared.', false,
     'Incorrect. Criminal intimidation under IPC §506 and anticipatory threats are actionable.'),
    ('s12','d','You must settle it privately first.', false,
     'Incorrect — and not safe. Private settlement is not a legal requirement and often emboldens the offender.'),
    -- s13
    ('s13','a','You must leave — oral notice is valid.', false,
     'Incorrect. §106 TPA and the Specific Relief Act require proper process. Oral same-day eviction is not lawful.'),
    ('s13','b','Eviction requires legal process; a landlord cannot forcibly remove you or your belongings without a court order.', true,
     'Correct. §106 TPA requires proper notice. §6 of the Specific Relief Act allows recovery of possession if dispossessed forcibly. State rent control laws add further protections.'),
    ('s13','c','You should respond with physical force.', false,
     'Incorrect. Call the police and document the incident — don''t escalate physically.'),
    ('s13','d','Police cannot intervene in any landlord–tenant dispute.', false,
     'Incorrect. Even if the core dispute is civil, police must prevent criminal force, intimidation, and breach of peace.'),
    -- s14
    ('s14','a','Private schools can refuse anyone they wish.', false,
     'Incorrect. §12(1)(c) RTE binds even private unaided schools to reserve 25% of entry-level seats.'),
    ('s14','b','Under RTE §12(1)(c), private unaided schools must reserve at least 25% of entry-level seats for children from EWS/disadvantaged groups in the neighborhood.', true,
     'Correct. §12(1)(c) RTE Act, 2009 mandates this reservation. Society for Unaided Private Schools v. Union of India (2012) upheld this provision.'),
    ('s14','c','Only government schools have to follow RTE.', false,
     'Incorrect. RTE binds aided and unaided private schools, with specified carve-outs.'),
    ('s14','d','Your child must be 3–6 years old for any law to apply.', false,
     'Incorrect. RTE covers ages 6 to 14.'),
    -- s15
    ('s15','a','This is an internal college matter — no legal recourse.', false,
     'Incorrect. Ragging is punishable under UGC Regulations 2009 and may attract criminal liability.'),
    ('s15','b','Ragging in any form is punishable under UGC anti-ragging regulations and may attract criminal liability; complain to the anti-ragging squad, UGC helpline 1800-180-5522, and police if needed.', true,
     'Correct. UGC Regulations on Curbing the Menace of Ragging (2009); Vishwa Jagriti Mission v. Central Government (2001).'),
    ('s15','c','Only physical ragging is illegal.', false,
     'Incorrect. Psychological, verbal, and any form of ragging is prohibited.'),
    ('s15','d','You must prove intent to harm before complaining.', false,
     'Incorrect. The definition of ragging under the regulations is broad; intent to physically harm is not a threshold.'),
    -- s16
    ('s16','a','You must sign — refusal is contempt.', false,
     'Incorrect. There is no duty to sign a confession, and Article 20(3) protects against compelled self-incrimination.'),
    ('s16','b','You have a right against self-incrimination. You need not sign. Confessions to police are generally inadmissible (Evidence Act §25), and confessions to a Magistrate require §164 CrPC safeguards.', true,
     'Correct. Article 20(3) Constitution; §25 Evidence Act (confession to police inadmissible); §164 CrPC (procedure for recording confessions before Magistrate).'),
    ('s16','c','You can only refuse if a lawyer instructs you to.', false,
     'Incorrect. The right is personal and does not depend on legal instruction, though consulting a lawyer is advisable.'),
    ('s16','d','You must sign first and challenge later.', false,
     'Incorrect. Signing under compulsion harms your case and still doesn''t create lawful admissibility issues for the police.'),
    -- s17
    ('s17','a','Police can hold someone as long as the investigation requires.', false,
     'Incorrect. Article 22(2) caps detention at 24 hours without magistrate''s order.'),
    ('s17','b','Every arrested person must be produced before a Magistrate within 24 hours (excluding travel time); holding beyond this without magistrate''s order is unlawful.', true,
     'Correct. Article 22(2) Constitution; §57 CrPC.'),
    ('s17','c','24 hours includes travel time to the nearest magistrate.', false,
     'Incorrect. Travel time is expressly excluded — but travel time is not a license for indefinite delay.'),
    ('s17','d','The rule applies only on weekdays.', false,
     'Incorrect. There is no weekday/weekend carve-out. Magistrates on duty handle such productions.'),
    -- s18
    ('s18','a','Hospitals are not covered by consumer law.', false,
     'Incorrect. IMA v. V.P. Shantha (1995) settled that paid medical services fall under consumer law.'),
    ('s18','b','Paid medical services fall under consumer protection law; undisclosed charges may be an unfair trade practice and actionable.', true,
     'Correct. CPA 2019 and IMA v. V.P. Shantha (1995). Free treatment is outside the scope; paid services are covered.'),
    ('s18','c','You can complain only after discharge.', false,
     'Incorrect. You may raise grievances during and after treatment.'),
    ('s18','d','Only government hospitals are subject to complaints.', false,
     'Incorrect. Private hospitals are squarely within consumer law when services are paid.'),
    -- s19
    ('s19','a','Security deposit belongs to the landlord.', false,
     'Incorrect. The deposit is your property held in trust for actual damage beyond normal wear.'),
    ('s19','b','Deposits cover actual damage beyond normal wear and tear; unjustified withholding can be challenged in civil court (and in some states/cases, consumer forum).', true,
     'Correct. Indian Contract Act governs; the Model Tenancy Act, 2021 where adopted limits deposits (typically 2 months residential) and requires return within a month.'),
    ('s19','c','You must wait 1 year before claiming.', false,
     'Incorrect. There is no such waiting period.'),
    ('s19','d','Only written rental agreements protect deposits.', false,
     'Incorrect. Verbal contracts can still give rise to rights, though written agreements are far easier to enforce.'),
    -- s20
    ('s20','a','Since the image is not real, it''s not a legal issue.', false,
     'Incorrect. Morphed obscene content is squarely within §67/§67A IT Act, regardless of whether the underlying image is authentic.'),
    ('s20','b','Creating, sharing, or transmitting such morphed content is a criminal offence under multiple provisions.', true,
     'Correct. IT Act §66E, §67, §67A; IPC §354C (voyeurism), §499 (defamation), §509 (insulting modesty).'),
    ('s20','c','Only the original creator is liable.', false,
     'Incorrect. Transmission and further distribution are independently punishable.'),
    ('s20','d','You need to know the creator''s identity first.', false,
     'Incorrect. Reporting can happen without that — investigation is the police''s job.')
ON CONFLICT DO NOTHING;

-- --- Scenario → law section mappings --------------------------------------

INSERT INTO scenario_law_links (scenario_id, section_id, relevance) VALUES
    ('s1', 'crpc-50', 'primary'), ('s1', 'art-22-1', 'primary'), ('s1', 'crpc-41', 'supporting'),
    ('s2', 'crpc-50a', 'primary'), ('s2', 'art-22-1', 'supporting'),
    ('s3', 'crpc-41a', 'primary'), ('s3', 'crpc-41', 'supporting'),
    ('s4', 'crpc-165', 'primary'), ('s4', 'crpc-100', 'primary'),
    ('s5', 'crpc-46-4', 'primary'),
    ('s6', 'posh-4', 'primary'), ('s6', 'posh-9', 'supporting'),
    ('s7', 'posh-9', 'primary'),
    ('s8', 'mat-12', 'primary'),
    ('s9', 'cpa-2-47', 'primary'), ('s9', 'cpa-ec-4', 'supporting'),
    ('s10', 'cpa-ec-4', 'primary'),
    ('s11', 'it-66c', 'primary'), ('s11', 'it-66d', 'primary'),
    ('s12', 'it-66e', 'primary'), ('s12', 'it-67', 'supporting'),
    ('s13', 'tpa-106', 'primary'), ('s13', 'sra-6', 'primary'),
    ('s14', 'rte-12', 'primary'),
    ('s15', 'ugc-ragging', 'primary'),
    ('s16', 'art-20-3', 'primary'),
    ('s17', 'art-22-2', 'primary'),
    ('s18', 'cpa-2-47', 'primary'),
    ('s19', 'tpa-106', 'supporting'),
    ('s20', 'it-66e', 'primary'), ('s20', 'it-67', 'primary')
ON CONFLICT DO NOTHING;

-- ============================================================================
-- 11. SEED DATA — ACT GUIDES
-- ============================================================================

INSERT INTO act_guides (id, title, icon, color) VALUES
    ('police-at-door',       'Police is at my door',           '🚔', 'blue'),
    ('employer-threatening', 'My employer is threatening me',  '💼', 'amber'),
    ('landlord-misbehaving', 'My landlord is misbehaving',     '🏠', 'emerald'),
    ('cheated-seller',       'I was cheated by a seller',      '🛒', 'purple'),
    ('online-incident',      'Something happened online',      '💻', 'rose'),
    ('school-unfair',        'My school/college is being unfair','🎓','teal')
ON CONFLICT (id) DO NOTHING;

INSERT INTO act_guide_items (guide_id, bucket, ord, content) VALUES
    -- police-at-door
    ('police-at-door','must_know',1,'Police must tell you the grounds of arrest (CrPC §50, Art. 22(1)).'),
    ('police-at-door','must_know',2,'For offences punishable up to 7 years, a §41A notice to appear is usually issued — not immediate arrest.'),
    ('police-at-door','must_know',3,'You have a right to inform a family member or friend (§50A CrPC).'),
    ('police-at-door','must_know',4,'You cannot be held beyond 24 hours without a magistrate''s order (Art. 22(2)).'),
    ('police-at-door','must_know',5,'A woman should not ordinarily be arrested after sunset (§46(4) CrPC).'),
    ('police-at-door','can_say',1,'What is the offence I am being arrested for?'),
    ('police-at-door','can_say',2,'Please show me your ID and — if required — the warrant.'),
    ('police-at-door','can_say',3,'I want to inform my family and consult a lawyer.'),
    ('police-at-door','can_say',4,'Please note the exact time of arrest.'),
    ('police-at-door','document',1,'Names and badge numbers of officers'),
    ('police-at-door','document',2,'Exact time of arrival and arrest'),
    ('police-at-door','document',3,'Items seized and the witnesses present'),
    ('police-at-door','document',4,'Whether proper witnesses were involved in any search'),
    ('police-at-door','call_first',1,'A family member'),
    ('police-at-door','call_first',2,'A lawyer — or National Legal Services Authority (helpline: 15100)'),
    ('police-at-door','call_first',3,'Emergency: 112'),
    -- employer-threatening
    ('employer-threatening','must_know',1,'Termination must follow due process as per your contract and applicable labour laws.'),
    ('employer-threatening','must_know',2,'If the threat involves harassment or retaliation for a POSH complaint, POSH Act protections apply.'),
    ('employer-threatening','must_know',3,'Final settlement (gratuity, PF, unpaid wages) is a statutory right.'),
    ('employer-threatening','must_know',4,'Termination during pregnancy that deprives maternity benefits is prohibited.'),
    ('employer-threatening','can_say',1,'Please put this in writing.'),
    ('employer-threatening','can_say',2,'I would like a copy of my employment contract and policies.'),
    ('employer-threatening','can_say',3,'What is the reason for termination?'),
    ('employer-threatening','can_say',4,'When will my final settlement be paid?'),
    ('employer-threatening','document',1,'Save emails, messages, memos'),
    ('employer-threatening','document',2,'Dates, times, and witnesses of incidents'),
    ('employer-threatening','document',3,'Pay slips and attendance records'),
    ('employer-threatening','document',4,'Any verbal threats (note words, place, time)'),
    ('employer-threatening','call_first',1,'HR / Internal Complaints Committee (for POSH)'),
    ('employer-threatening','call_first',2,'Labour Commissioner (state helpline varies)'),
    ('employer-threatening','call_first',3,'Shram Suvidha portal (for central PF/labour)'),
    ('employer-threatening','call_first',4,'A labour lawyer'),
    -- landlord-misbehaving
    ('landlord-misbehaving','must_know',1,'Eviction requires legal process — never by force (§6 Specific Relief Act).'),
    ('landlord-misbehaving','must_know',2,'A landlord cannot cut off essential services (water, power) as pressure.'),
    ('landlord-misbehaving','must_know',3,'Security deposit belongs to you, subject to deductions for actual damage.'),
    ('landlord-misbehaving','must_know',4,'Under the Model Tenancy Act (where adopted), deposit is capped and must be returned within a month.'),
    ('landlord-misbehaving','can_say',1,'Please give me written notice.'),
    ('landlord-misbehaving','can_say',2,'What is the reason for eviction?'),
    ('landlord-misbehaving','can_say',3,'I will not leave without legal process.'),
    ('landlord-misbehaving','document',1,'Photos/videos of the flat''s condition'),
    ('landlord-misbehaving','document',2,'All rent receipts / payment proofs'),
    ('landlord-misbehaving','document',3,'Copies of the rental agreement'),
    ('landlord-misbehaving','document',4,'Witnesses to any confrontation'),
    ('landlord-misbehaving','call_first',1,'Local police (for force/intimidation — dial 112)'),
    ('landlord-misbehaving','call_first',2,'Rent Control Authority (where applicable)'),
    ('landlord-misbehaving','call_first',3,'Legal aid: NALSA 15100'),
    -- cheated-seller
    ('cheated-seller','must_know',1,'Defective goods → right to refund, replacement, or repair.'),
    ('cheated-seller','must_know',2,'E-commerce platforms are liable under the E-Commerce Rules, 2020.'),
    ('cheated-seller','must_know',3,'Misleading descriptions and withheld information are unfair trade practices.'),
    ('cheated-seller','must_know',4,'Consumer Commissions hear disputes by value thresholds.'),
    ('cheated-seller','can_say',1,'I want a full refund for this defective product.'),
    ('cheated-seller','can_say',2,'What is your grievance redressal process?'),
    ('cheated-seller','can_say',3,'Please give me a written response within a stated time.'),
    ('cheated-seller','document',1,'Order ID, listing screenshots, invoice'),
    ('cheated-seller','document',2,'Payment proof'),
    ('cheated-seller','document',3,'Photos/videos of defect'),
    ('cheated-seller','document',4,'All messages with the seller'),
    ('cheated-seller','call_first',1,'National Consumer Helpline: 1915'),
    ('cheated-seller','call_first',2,'consumerhelpline.gov.in (online complaint)'),
    ('cheated-seller','call_first',3,'District Consumer Commission (if unresolved)'),
    -- online-incident
    ('online-incident','must_know',1,'Financial fraud: dial 1930 immediately — speed matters for freezing funds.'),
    ('online-incident','must_know',2,'Report at cybercrime.gov.in (non-financial: harassment, impersonation, threats).'),
    ('online-incident','must_know',3,'Don''t delete evidence — preserve screenshots, messages, URLs.'),
    ('online-incident','must_know',4,'Intermediaries have legal duties under the IT Rules, 2021.'),
    ('online-incident','can_say',1,'(Mostly online/phone reporting — keep language clear and factual.)'),
    ('online-incident','can_say',2,'Also report to the platform itself for fast action on content removal.'),
    ('online-incident','document',1,'Screenshots with the URL visible'),
    ('online-incident','document',2,'Timestamps'),
    ('online-incident','document',3,'User IDs / profile handles involved'),
    ('online-incident','document',4,'Any messages — preserve originals, don''t forward carelessly'),
    ('online-incident','call_first',1,'Cyber crime helpline: 1930 (financial fraud)'),
    ('online-incident','call_first',2,'cybercrime.gov.in'),
    ('online-incident','call_first',3,'Local police / cyber cell'),
    ('online-incident','call_first',4,'Emergency threats: 112'),
    -- school-unfair
    ('school-unfair','must_know',1,'Ragging is prohibited and punishable under UGC Regulations.'),
    ('school-unfair','must_know',2,'RTE guarantees free education for children 6–14, with 25% reservation in private schools.'),
    ('school-unfair','must_know',3,'Capitation fees are illegal in many states.'),
    ('school-unfair','must_know',4,'Students with disabilities have protections under the RPwD Act, 2016.'),
    ('school-unfair','can_say',1,'Please provide a written response and cite the regulation.'),
    ('school-unfair','can_say',2,'What is your grievance redressal procedure?'),
    ('school-unfair','document',1,'All official communications'),
    ('school-unfair','document',2,'Incident dates, witnesses, photos/videos (if safe)'),
    ('school-unfair','document',3,'Fee receipts and admission letters'),
    ('school-unfair','call_first',1,'Anti-ragging helpline: 1800-180-5522'),
    ('school-unfair','call_first',2,'UGC / AICTE / NCTE grievance portals'),
    ('school-unfair','call_first',3,'School/college management in writing'),
    ('school-unfair','call_first',4,'State Education Department')
ON CONFLICT DO NOTHING;

-- ============================================================================
-- 12. SM-2 STORED PROCEDURE (optional — mirror of client-side algorithm)
-- ============================================================================
-- Apply SM-2 server-side when recording an attempt, keeping schedule in sync.

CREATE OR REPLACE FUNCTION record_attempt(
    p_user_id UUID,
    p_scenario_id TEXT,
    p_chosen_code CHAR(1),
    p_is_correct BOOLEAN,
    p_response_ms INT
) RETURNS VOID AS $$
DECLARE
    q INT;
    ef NUMERIC(4,2);
    reps INT;
    intv INT;
    cur RECORD;
BEGIN
    -- Map attempt → quality (0-5)
    IF p_is_correct THEN
        q := CASE WHEN p_response_ms < 15000 THEN 5 ELSE 4 END;
    ELSE
        q := CASE WHEN p_response_ms < 30000 THEN 2 ELSE 1 END;
    END IF;

    INSERT INTO user_attempts (user_id, scenario_id, chosen_code, is_correct, response_ms, client_ts)
    VALUES (p_user_id, p_scenario_id, p_chosen_code, p_is_correct, p_response_ms, now());

    SELECT ease_factor, repetitions, interval_days INTO cur
    FROM user_revision_schedule
    WHERE user_id = p_user_id AND scenario_id = p_scenario_id;

    ef   := COALESCE(cur.ease_factor, 2.50);
    reps := COALESCE(cur.repetitions, 0);
    intv := COALESCE(cur.interval_days, 0);

    IF q < 3 THEN
        reps := 0;
        intv := 1;
    ELSE
        reps := reps + 1;
        IF reps = 1 THEN intv := 1;
        ELSIF reps = 2 THEN intv := 3;
        ELSE intv := GREATEST(1, ROUND(intv * ef));
        END IF;
        ef := GREATEST(1.3, ef + 0.1 - (5-q) * (0.08 + (5-q)*0.02));
    END IF;

    INSERT INTO user_revision_schedule (user_id, scenario_id, ease_factor, repetitions, interval_days, next_due)
    VALUES (p_user_id, p_scenario_id, ef, reps, intv, now() + (intv || ' days')::INTERVAL)
    ON CONFLICT (user_id, scenario_id) DO UPDATE
    SET ease_factor = EXCLUDED.ease_factor,
        repetitions = EXCLUDED.repetitions,
        interval_days = EXCLUDED.interval_days,
        next_due = EXCLUDED.next_due,
        updated_at = now();
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 13. USEFUL VIEWS
-- ============================================================================

-- Scenarios with full choice + law context (denormalized for easy read)
CREATE OR REPLACE VIEW v_scenario_full AS
SELECT
    s.id,
    s.domain,
    s.difficulty,
    s.title,
    s.situation,
    s.concept,
    s.status,
    (SELECT json_agg(json_build_object(
        'code', c.choice_code, 'text', c.text, 'correct', c.is_correct, 'explanation', c.explanation
    ) ORDER BY c.choice_code) FROM scenario_choices c WHERE c.scenario_id = s.id) AS choices,
    (SELECT json_agg(json_build_object(
        'id', l.id, 'act', a.short_name, 'number', l.number, 'title', l.title, 'simplified', l.simplified, 'source', l.source_cite
    )) FROM scenario_law_links sl
      JOIN law_sections l ON l.id = sl.section_id
      JOIN acts a ON a.id = l.act_id
      WHERE sl.scenario_id = s.id) AS laws
FROM scenarios s;

-- Per-user mastery by domain (used by ProgressView)
CREATE OR REPLACE VIEW v_user_mastery AS
SELECT
    u.id AS user_id,
    s.domain,
    COUNT(DISTINCT s.id) FILTER (WHERE EXISTS (
        SELECT 1 FROM user_attempts a
        WHERE a.user_id = u.id AND a.scenario_id = s.id
    )) AS attempted,
    COUNT(DISTINCT s.id) AS total,
    COUNT(DISTINCT s.id) FILTER (WHERE EXISTS (
        SELECT 1 FROM (
            SELECT DISTINCT ON (scenario_id) scenario_id, is_correct
            FROM user_attempts WHERE user_id = u.id
            ORDER BY scenario_id, server_ts ASC
        ) first WHERE first.scenario_id = s.id AND first.is_correct
    ))::NUMERIC / NULLIF(COUNT(DISTINCT s.id), 0) AS mastery
FROM user_profiles u
CROSS JOIN scenarios s
WHERE s.status = 'published'
GROUP BY u.id, s.domain;

-- ============================================================================
-- 14. NEO4J — KNOWLEDGE GRAPH (reference schema)
-- ============================================================================
-- Postgres is the source of truth; Neo4j stores relationship-heavy queries
-- (e.g. "which sections apply to THIS situation type"). Run in Neo4j cypher-shell:
--
-- // Constraints
-- CREATE CONSTRAINT law_section_id IF NOT EXISTS
--   FOR (n:LawSection) REQUIRE n.id IS UNIQUE;
-- CREATE CONSTRAINT act_id IF NOT EXISTS
--   FOR (n:Act) REQUIRE n.id IS UNIQUE;
-- CREATE CONSTRAINT concept_name IF NOT EXISTS
--   FOR (n:Concept) REQUIRE n.name IS UNIQUE;
-- CREATE CONSTRAINT actor_name IF NOT EXISTS
--   FOR (n:Actor) REQUIRE n.name IS UNIQUE;
-- CREATE CONSTRAINT situation_id IF NOT EXISTS
--   FOR (n:Situation) REQUIRE n.id IS UNIQUE;
--
-- // Relationships
-- // (:LawSection)-[:BELONGS_TO]->(:Act)
-- // (:LawSection)-[:CITES]->(:LawSection)
-- // (:LawSection)-[:APPLIES_TO]->(:Situation)
-- // (:LawSection)-[:GRANTS_RIGHT]->(:Concept)
-- // (:LawSection)-[:IMPOSES_DUTY]->(:Actor)
-- // (:Case)-[:INTERPRETS]->(:LawSection)
--
-- // Example query: for a user in situation "police_at_door", fetch relevant sections
-- // MATCH (sit:Situation {id:'police_at_door'})<-[:APPLIES_TO]-(s:LawSection)
-- // OPTIONAL MATCH (c:Case)-[:INTERPRETS]->(s)
-- // RETURN s, collect(c) AS cases;
--
-- // Mirror jobs: Postgres → Neo4j sync via Kafka (see design doc §2.4).
-- ============================================================================

-- ============================================================================
-- END OF SCHEMA
-- ============================================================================
-- Next steps for a full deployment:
--   1. Create a partitioning maintenance job for user_attempts (monthly).
--   2. Stand up Neo4j and ingest the schema above via cypher-shell.
--   3. Wire the HTML app's data layer to a REST/GraphQL API over this schema.
--   4. Set up a reviewer role (RBAC) — reviewer accounts should be separate
--      from end-user accounts and logged to review_decisions.
--   5. Add i18n tables for Hindi/Tamil/Bengali/Telugu translations of
--      scenarios.situation, scenario_choices.text, scenario_choices.explanation,
--      act_guide_items.content, and law_sections.simplified (source_cite stays as-is).
-- ============================================================================
