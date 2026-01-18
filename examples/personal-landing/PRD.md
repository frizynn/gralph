# PRD: Personal Landing Page for Juan Francisco Lebrero (GenAI Consultant)

## Introduction / Overview
Create a single-page, English-language landing site for Juan Francisco Lebrero, an IA consultant and GenAI Research lead at Mercado Libre, focused on establishing authority and generating qualified consulting leads and contact requests.

## Goals
- Establish credibility in GenAI strategy and research for enterprises and SMEs.
- Drive visitors to book a call (primary CTA) and collect contact info.
- Present concise thought-leadership signals (short insights/blog teasers) without heavy CMS.
- Be SEO-ready for personal name + GenAI consulting queries.

## User Stories

### US-001: Hero & Credibility Block
**Description:** As a visitor, I want immediate clarity on Juan’s role, expertise, and credibility so I know I’m in the right place.

**Acceptance Criteria:**
- [ ] Above-the-fold hero with name, title ("GenAI Consultant & Research Lead at Mercado Libre"), 1–2 line value proposition, and prominent "Book a Call" button.
- [ ] Logos or short text badges for Mercado Libre and key domains (GenAI strategy, enterprise/SME).
- [ ] Typecheck/lint passes.
- [ ] Verify in browser using dev-browser skill.

### US-002: Services & Outcomes
**Description:** As a prospective client (enterprise or SME), I want to see the services and expected outcomes so I can assess fit quickly.

**Acceptance Criteria:**
- [ ] Section with 3–5 service cards (e.g., GenAI strategy sprints, research deep-dives, technical architecture reviews, capability roadmaps).
- [ ] Each card lists outcome and who it’s for (enterprise vs SME) in one line.
- [ ] CTA row or repeated "Book a Call" link after the section.
- [ ] Typecheck/lint passes.
- [ ] Verify in browser using dev-browser skill.

### US-003: Case Signal / Highlights
**Description:** As a visitor, I want proof points so I trust Juan’s experience.

**Acceptance Criteria:**
- [ ] Short case-highlight strip (3–4 bullets) focusing on business impact (e.g., latency reduction, cost savings, deployment scale) without disclosing confidential data.
- [ ] Includes at least one research/architecture highlight and one market-facing impact highlight.
- [ ] Typecheck/lint passes.
- [ ] Verify in browser using dev-browser skill.

### US-004: Thought Leadership Teasers
**Description:** As a visitor, I want to sense Juan’s thinking without reading long posts, so I gain confidence.

**Acceptance Criteria:**
- [ ] Section with 2–3 micro-insights (100–150 chars) linking to external profiles (LinkedIn, Medium, etc.).
- [ ] Optional RSS/email capture widget link stub for future expansion (no backend required).
- [ ] Typecheck/lint passes.
- [ ] Verify in browser using dev-browser skill.

### US-005: Contact / Booking Flow
**Description:** As a motivated visitor, I want a simple way to book a call so I can engage immediately.

**Acceptance Criteria:**
- [ ] Primary CTA button scrolls to or opens scheduling (e.g., Calendly stub URL config variable) in new tab.
- [ ] Backup email contact link with mailto and prefilled subject.
- [ ] Light-contact form option (name, email, company, project summary) with front-end validation only; submit can be a stub/placeholder action.
- [ ] Confirmation microcopy after form submission attempt (even if stubbed).
- [ ] Typecheck/lint passes.
- [ ] Verify in browser using dev-browser skill.

### US-006: Trust & Bio Section
**Description:** As a visitor, I want a concise bio to understand Juan’s background and relevance.

**Acceptance Criteria:**
- [ ] 2–3 sentence bio referencing Mercado Libre role and GenAI research focus.
- [ ] Optional avatar/headshot placeholder and social links (LinkedIn, GitHub/Google Scholar if available).
- [ ] Typecheck/lint passes.
- [ ] Verify in browser using dev-browser skill.

### US-007: Performance & SEO Readiness
**Description:** As a site owner, I want the page to be fast and discoverable so it ranks and converts.

**Acceptance Criteria:**
- [ ] Core Web Vitals-friendly: optimized images, lazy loading where relevant, minimal blocking assets.
- [ ] Meta tags: title, description, Open Graph, Twitter card; schema.org Person markup including jobTitle and worksFor.
- [ ] Lighthouse performance and SEO scores ≥ 90 (desktop) using default test environment.
- [ ] Typecheck/lint passes.

## Functional Requirements
- FR-1: Single-page layout with anchor navigation covering Hero, Services, Case Highlights, Thought Leadership, Bio/Trust, Contact/Booking.
- FR-2: Configurable primary CTA URL (scheduler) via environment/config variable.
- FR-3: Reusable CTA buttons placed in Hero and Services sections.
- FR-4: Service cards must support audience labels (enterprise/SME).
- FR-5: Contact form uses client-side validation; submission can be stubbed but must show confirmation message.
- FR-6: SEO metadata and schema.org Person markup rendered in the page head.
- FR-7: Accessibility: keyboard-focusable CTAs, sufficient contrast, aria labels on form controls, semantic headings.
- FR-8: Performance optimizations: image compression guidance, defer noncritical scripts, avoid heavy libraries.

## Non-Goals (Out of Scope)
- No multi-language toggle (English only for this version).
- No backend for form submission or scheduling; front-end stubs only.
- No blog CMS; only teaser links to external content.
- No user authentication or dashboards.

## Design Considerations
- Style: single-section minimalist with strong typography; avoid heavy visuals; use restrained color palette with high contrast.
- Repeated primary CTA for conversion (Hero + post-services).
- Keep copy concise; avoid jargon; emphasize outcomes over tech specs.

## Technical Considerations
- Favor static/site-generator-friendly approach (e.g., pure HTML/CSS/JS or lightweight framework) to keep load fast.
- Provide hooks/configs for scheduler URL and social links without code change.
- Include guidance for image dimensions and compression if assets are added later.

## Success Metrics
- Primary: Click-through rate on "Book a Call" button ≥ 5% of visits.
- Secondary: Time on page ≥ 90 seconds; bounce rate ≤ 60%; Lighthouse performance/SEO ≥ 90 desktop.

## Open Questions
- Preferred scheduler tool/URL (Calendly, Cal.com, etc.)?
- Which external profiles to link for thought-leadership (LinkedIn, Medium, Substack)?
- Is a headshot asset available, or should we use a neutral placeholder?
- Any legal/disclaimer text required for consulting engagements?
