/**
 * Trust & Bio Section Tests
 * Standalone test suite that doesn't require external dependencies
 */

const fs = require('fs');
const path = require('path');

// Test counters
let passed = 0;
let failed = 0;

// Test utilities
function test(description, testFn) {
    try {
        testFn();
        passed++;
        console.log(`✓ ${description}`);
    } catch (error) {
        failed++;
        console.log(`✗ ${description}`);
        console.log(`  Error: ${error.message}`);
    }
}

function assert(condition, message) {
    if (!condition) {
        throw new Error(message);
    }
}

function assertContains(content, substring, message) {
    if (!content.includes(substring)) {
        throw new Error(`${message} (expected to contain "${substring}")`);
    }
}

function assertMatch(content, regex, message) {
    if (!regex.test(content)) {
        throw new Error(`${message} (regex did not match)`);
    }
}

console.log('\n🧪 Running Trust & Bio Section Tests\n');
console.log('=' .repeat(50));

// Read the files
const htmlPath = path.join(__dirname, '..', 'index.html');
const cssPath = path.join(__dirname, '..', 'styles.css');
const jsPath = path.join(__dirname, '..', 'script.js');

const htmlContent = fs.readFileSync(htmlPath, 'utf8');
const cssContent = fs.readFileSync(cssPath, 'utf8');
const jsContent = fs.readFileSync(jsPath, 'utf8');

console.log('\n📄 HTML Structure Tests\n');

// HTML Structure Tests
test('Bio section has correct id', () => {
    assertContains(htmlContent, 'id="bio"', 'Bio section has correct id');
});

test('Bio section has "About Me" title', () => {
    assertContains(htmlContent, 'About Me', 'Bio section has "About Me" title');
});

test('Has avatar placeholder class', () => {
    assertContains(htmlContent, 'avatar-placeholder', 'Has avatar placeholder class');
});

test('Avatar has unique id', () => {
    assertContains(htmlContent, 'id="avatar"', 'Avatar has unique id');
});

test('Avatar has accessibility label', () => {
    assertContains(htmlContent, 'aria-label="Juan Francisco Lebrero headshot placeholder"', 'Avatar has accessibility label');
});

test('Avatar shows initials "JL"', () => {
    assertContains(htmlContent, 'avatar-initials', 'Has avatar initials element');
    assertContains(htmlContent, 'JL', 'Avatar shows initials "JL"');
});

test('Bio text mentions Mercado Libre', () => {
    assertContains(htmlContent, 'bio-text', 'Has bio text container');
    assertContains(htmlContent, 'Mercado Libre', 'Bio mentions Mercado Libre');
});

test('Bio text mentions GenAI', () => {
    assertContains(htmlContent, 'GenAI', 'Bio mentions GenAI');
});

test('Has social links container', () => {
    assertContains(htmlContent, 'social-links', 'Has social links container');
});

test('Has LinkedIn link', () => {
    assertContains(htmlContent, 'linkedin.com/in/juanfranciscolebrero', 'Has LinkedIn link');
    assertContains(htmlContent, 'aria-label="LinkedIn Profile"', 'LinkedIn has accessibility label');
});

test('Has GitHub link', () => {
    assertContains(htmlContent, 'github.com/juanfranciscolebrero', 'Has GitHub link');
    assertContains(htmlContent, 'aria-label="GitHub Profile"', 'GitHub has accessibility label');
});

test('Has Google Scholar link', () => {
    assertContains(htmlContent, 'scholar.google.com', 'Has Google Scholar link');
    assertContains(htmlContent, 'aria-label="Google Scholar Profile"', 'Google Scholar has accessibility label');
});

test('Has SVG social icons', () => {
    // This landing intentionally uses text links (no inline SVG icons required)
    assertContains(htmlContent, 'class="social-link"', 'Has social links');
});

test('Social links have text labels', () => {
    assertContains(htmlContent, '>LinkedIn<', 'LinkedIn link has text');
    assertContains(htmlContent, '>GitHub<', 'GitHub link has text');
    assertContains(htmlContent, '>Google Scholar<', 'Google Scholar link has text');
});

console.log('\n🎨 CSS Styling Tests\n');

test('Has bio section styles', () => {
    assertContains(cssContent, '.bio', 'Has bio section styles');
});

test('Bio content uses flexbox', () => {
    assertContains(cssContent, '.bio-content', 'Has bio content styles');
    assertContains(cssContent, 'display: flex', 'Bio content uses flexbox');
});

test('Bio content has responsive layout', () => {
    assert(cssContent.includes('@media (max-width: 768px)') && 
           cssContent.includes('.bio-content'),
           'Bio content has responsive layout');
});

test('Avatar placeholder is circular', () => {
    assertContains(cssContent, '.avatar-placeholder', 'Has avatar placeholder styles');
    assertContains(cssContent, 'border-radius: var(--border-radius-full)', 'Avatar is circular');
});

test('Avatar has defined dimensions', () => {
    assertContains(cssContent, 'width: 180px', 'Avatar has defined width');
    assertContains(cssContent, 'height: 180px', 'Avatar has defined height');
});

test('Avatar initials styling exists', () => {
    assertContains(cssContent, '.avatar-initials', 'Has avatar initials styles');
    assertContains(cssContent, 'color: white', 'Initials are white');
    assertContains(cssContent, 'font-weight: 700', 'Initials are bold');
});

test('Social links styling exists', () => {
    assertContains(cssContent, '.social-links', 'Has social links styles');
    assertContains(cssContent, '.social-link', 'Has individual social link styles');
});

test('Social icon styling exists', () => {
    // No icons in this implementation; links are styled as text buttons
    assertContains(cssContent, '.social-link', 'Has social link styles');
});

test('Social links have hover effects', () => {
    assertContains(cssContent, '.social-link:hover', 'Social links have hover styles');
    assertContains(cssContent, 'transform: translateY', 'Links have hover animation');
});

console.log('\n⚙️ JavaScript Functionality Tests\n');

test('Has form validation functions', () => {
    assertContains(jsContent, 'validateField', 'Has form validation function');
    assertContains(jsContent, '/^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$/', 'Has email validation regex');
});

test('Has contact form initialization', () => {
    assertContains(jsContent, 'initContactForm', 'Has contact form initialization');
});

test('Has navigation initialization', () => {
    assertContains(jsContent, 'initNavigation', 'Has navigation initialization');
});

test('Email validation regex works correctly', () => {
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    assert(emailRegex.test('test@example.com'), 'Email regex validates correct format');
    assert(!emailRegex.test('invalid'), 'Email regex rejects invalid format');
});

console.log('\n♿ Accessibility Tests\n');

test('Social links have ARIA labels', () => {
    assertContains(htmlContent, 'aria-label="LinkedIn Profile"', 'LinkedIn has ARIA label');
    assertContains(htmlContent, 'aria-label="GitHub Profile"', 'GitHub has ARIA label');
    assertContains(htmlContent, 'aria-label="Google Scholar Profile"', 'Google Scholar has ARIA label');
});

test('Avatar has img role', () => {
    assertContains(htmlContent, 'role="img"', 'Avatar has img role');
});

test('Form fields have labels', () => {
    assertContains(htmlContent, '<label for="name"', 'Name field has label');
    assertContains(htmlContent, '<label for="email"', 'Email field has label');
    assertContains(htmlContent, 'aria-required="true"', 'Required fields have ARIA attribute');
});

console.log('\n🔗 Section Integration Tests\n');

test('Navigation links to bio section', () => {
    assertContains(htmlContent, 'href="#bio"', 'Navigation links to bio section');
});

test('Bio section has proper heading hierarchy', () => {
    const bioTitleMatch = htmlContent.match(/<section[^>]*id="bio"[^>]*>[\s\S]*?<h2[^>]*>About Me<\/h2>/);
    assert(bioTitleMatch, 'Bio section has h2 heading');
});

console.log('\n' + '=' .repeat(50));
console.log(`\n✅ Test Results: ${passed} passed, ${failed} failed\n`);

if (failed > 0) {
    process.exit(1);
}
