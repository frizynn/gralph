/**
 * Landing Page JavaScript
 * Handles form validation, smooth scrolling, and interactions
 */

// Configuration - could be loaded from environment variables in production
const CONFIG = {
    calendlyUrl: 'https://calendly.com/juanfranciscolebrero/consultation',
    emailAddress: 'juanfranciscolebrero@example.com',
    emailSubject: 'GenAI Consulting Inquiry'
};

// DOM Elements
const elements = {
    contactForm: null,
    formConfirmation: null,
    calendlyLink: null,
    emailLink: null,
    submitButton: null
};

/**
 * Initialize the page after DOM is loaded
 */
function init() {
    // Cache DOM elements
    elements.contactForm = document.getElementById('contact-form');
    elements.formConfirmation = document.getElementById('form-confirmation');
    elements.calendlyLink = document.getElementById('calendly-link');
    elements.emailLink = document.getElementById('email-link');
    elements.submitButton = document.getElementById('submit-button');

    // Initialize components
    initNavigation();
    initContactForm();
    initContactLinks();
    initSmoothScroll();
}

/**
 * Initialize navigation highlighting based on scroll position
 */
function initNavigation() {
    const sections = document.querySelectorAll('section[id]');
    const navLinks = document.querySelectorAll('.nav-link');

    function updateActiveNav() {
        const scrollPos = window.scrollY + 100;

        sections.forEach(section => {
            const sectionTop = section.offsetTop;
            const sectionHeight = section.offsetHeight;
            const sectionId = section.getAttribute('id');

            if (scrollPos >= sectionTop && scrollPos < sectionTop + sectionHeight) {
                navLinks.forEach(link => {
                    link.classList.remove('active');
                    if (link.getAttribute('href') === `#${sectionId}`) {
                        link.classList.add('active');
                    }
                });
            }
        });
    }

    // Add active class styling
    const style = document.createElement('style');
    style.textContent = '.nav-link.active { color: var(--color-highlight); background-color: var(--color-background-alt); }';
    document.head.appendChild(style);

    window.addEventListener('scroll', updateActiveNav, { passive: true });
    updateActiveNav(); // Initial call
}

/**
 * Initialize contact form with validation
 */
function initContactForm() {
    if (!elements.contactForm) return;

    // Form validation rules
    const validators = {
        name: {
            validate: (value) => value.trim().length >= 2,
            message: 'Please enter your name (at least 2 characters)'
        },
        email: {
            validate: (value) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value.trim()),
            message: 'Please enter a valid email address'
        },
        'project-summary': {
            validate: (value) => value.trim().length >= 10,
            message: 'Please provide a project summary (at least 10 characters)'
        }
    };

    // Real-time validation on blur
    const inputs = elements.contactForm.querySelectorAll('input[required], textarea[required]');
    inputs.forEach(input => {
        input.addEventListener('blur', () => validateField(input, validators));
        input.addEventListener('input', () => {
            // Clear error when user starts typing
            const errorSpan = document.getElementById(`${input.id}-error`);
            if (errorSpan && errorSpan.textContent) {
                clearFieldError(input);
            }
        });
    });

    // Form submission
    elements.contactForm.addEventListener('submit', (e) => {
        e.preventDefault();

        // Validate all fields
        let isValid = true;
        inputs.forEach(input => {
            if (!validateField(input, validators)) {
                isValid = false;
            }
        });

        if (isValid) {
            handleFormSubmission();
        }
    });
}

/**
 * Validate a single form field
 * @param {HTMLInputElement|HTMLTextAreaElement} field - The field to validate
 * @param {Object} validators - The validators object
 * @returns {boolean} - Whether the field is valid
 */
function validateField(field, validators) {
    const fieldName = field.name;
    const validator = validators[fieldName];

    if (!validator) return true;

    const isValid = validator.validate(field.value);
    const errorSpan = document.getElementById(`${field.id}-error`);

    if (!isValid) {
        showFieldError(field, errorSpan, validator.message);
        return false;
    } else {
        clearFieldError(field, errorSpan);
        return true;
    }
}

/**
 * Show error message for a field
 */
function showFieldError(field, errorSpan, message) {
    if (errorSpan) {
        errorSpan.textContent = message;
        field.setAttribute('aria-invalid', 'true');
    }
}

/**
 * Clear error message for a field
 */
function clearFieldError(field, errorSpan) {
    if (errorSpan) {
        errorSpan.textContent = '';
        field.removeAttribute('aria-invalid');
    }
}

/**
 * Handle form submission
 */
function handleFormSubmission() {
    // Collect form data
    const formData = new FormData(elements.contactForm);
    const data = {
        name: formData.get('name'),
        email: formData.get('email'),
        company: formData.get('company') || 'Not provided',
        projectSummary: formData.get('project-summary'),
        timestamp: new Date().toISOString()
    };

    // Log form data (in production, this would be sent to a server)
    console.log('Form submitted:', data);

    // Disable submit button during "submission"
    elements.submitButton.disabled = true;
    elements.submitButton.textContent = 'Sending...';

    // Simulate server delay
    setTimeout(() => {
        // Show confirmation
        elements.contactForm.hidden = true;
        elements.formConfirmation.hidden = false;

        // Reset button state
        elements.submitButton.disabled = false;
        elements.submitButton.textContent = 'Send Message';

        // Scroll to confirmation
        elements.formConfirmation.scrollIntoView({ behavior: 'smooth', block: 'center' });

        // Log success
        console.log('Form submission successful');
    }, 1000);
}

/**
 * Initialize contact links with configured URLs
 */
function initContactLinks() {
    // Set Calendly link
    if (elements.calendlyLink) {
        elements.calendlyLink.href = CONFIG.calendlyUrl;
    }

    // Set email link with subject
    if (elements.emailLink) {
        const mailtoUrl = `mailto:${CONFIG.emailAddress}?subject=${encodeURIComponent(CONFIG.emailSubject)}`;
        elements.emailLink.href = mailtoUrl;
    }
}

/**
 * Initialize smooth scrolling for anchor links
 */
function initSmoothScroll() {
    document.querySelectorAll('a[href^="#"]').forEach(anchor => {
        anchor.addEventListener('click', function(e) {
            const targetId = this.getAttribute('href');
            if (targetId === '#') return;

            const targetElement = document.querySelector(targetId);
            if (targetElement) {
                e.preventDefault();

                const navHeight = document.querySelector('.nav').offsetHeight;
                const targetPosition = targetElement.offsetTop - navHeight;

                window.scrollTo({
                    top: targetPosition,
                    behavior: 'smooth'
                });
            }
        });
    });
}

/**
 * Utility: Debounce function for performance
 */
function debounce(func, wait) {
    let timeout;
    return function executedFunction(...args) {
        const later = () => {
            clearTimeout(timeout);
            func(...args);
        };
        clearTimeout(timeout);
        timeout = setTimeout(later, wait);
    };
}

// Initialize when DOM is ready
if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
} else {
    init();
}
