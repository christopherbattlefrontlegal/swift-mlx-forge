// Forge — site interactions
// Copy buttons, scroll-reveal, mobile nav, and active-section highlighting.
// No dependencies; progressive enhancement only.

(function () {
  "use strict";

  /* ----------------------------------------------------------- Copy buttons */
  var copyButtons = document.querySelectorAll("[data-copy]");
  copyButtons.forEach(function (button) {
    var originalText = button.textContent;
    button.addEventListener("click", function () {
      var text = button.dataset.copy;
      var done = function () {
        button.textContent = "Copied ✓";
        window.setTimeout(function () {
          button.textContent = originalText;
        }, 1600);
      };
      var fail = function () {
        button.textContent = "Select & copy above";
        window.setTimeout(function () {
          button.textContent = originalText;
        }, 2000);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done, fail);
      } else {
        // Fallback for older / non-secure contexts
        try {
          var ta = document.createElement("textarea");
          ta.value = text;
          ta.setAttribute("readonly", "");
          ta.style.position = "absolute";
          ta.style.left = "-9999px";
          document.body.appendChild(ta);
          ta.select();
          document.execCommand("copy");
          document.body.removeChild(ta);
          done();
        } catch (e) {
          fail();
        }
      }
    });
  });

  /* ----------------------------------------------------------- Scroll reveal */
  var revealEls = document.querySelectorAll(".reveal");

  if (!("IntersectionObserver" in window)) {
    revealEls.forEach(function (el) {
      el.classList.add("is-visible");
    });
  } else {
    var io = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry) {
          if (entry.isIntersecting) {
            // Stagger siblings within the same band slightly for a nicer cascade.
            var target = entry.target;
            var siblings = Array.prototype.slice.call(
              target.parentElement.querySelectorAll(":scope > .reveal")
            );
            var idx = siblings.indexOf(target);
            if (idx > 0) {
              target.style.transitionDelay = Math.min(idx * 70, 280) + "ms";
            }
            target.classList.add("is-visible");
            io.unobserve(target);
          }
        });
      },
      { threshold: 0.12, rootMargin: "0px 0px -8% 0px" }
    );
    revealEls.forEach(function (el) {
      io.observe(el);
    });
  }

  /* ----------------------------------------------------------- Mobile nav */
  var navToggle = document.querySelector(".nav-toggle");
  var mobileNav = document.getElementById("mobile-nav");

  if (navToggle && mobileNav) {
    var setOpen = function (open) {
      navToggle.setAttribute("aria-expanded", open ? "true" : "false");
      mobileNav.classList.toggle("open", open);
      document.body.style.overflow = open ? "hidden" : "";
    };

    navToggle.addEventListener("click", function () {
      var open = navToggle.getAttribute("aria-expanded") === "true";
      setOpen(!open);
    });

    // Close on link click
    mobileNav.querySelectorAll("a").forEach(function (link) {
      link.addEventListener("click", function () {
        setOpen(false);
      });
    });

    // Close on Escape
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape") setOpen(false);
    });

    // Close if resized up to desktop
    window.addEventListener("resize", function () {
      if (window.innerWidth > 760) setOpen(false);
    });
  }

  /* ----------------------------------------------------------- Active section in header nav */
  var navLinks = Array.prototype.slice.call(
    document.querySelectorAll(".site-header nav a")
  );
  var sectionMap = {};
  navLinks.forEach(function (link) {
    var hash = link.getAttribute("href");
    if (hash && hash.charAt(0) === "#") {
      var sec = document.querySelector(hash);
      if (sec) sectionMap[hash] = { link: link, el: sec };
    }
  });

  if ("IntersectionObserver" in window && Object.keys(sectionMap).length) {
    var spy = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry) {
          var hash = "#" + entry.target.id;
          var entry2 = sectionMap[hash];
          if (!entry2) return;
          if (entry.isIntersecting) {
            navLinks.forEach(function (l) {
              l.classList.remove("active");
            });
            entry2.link.classList.add("active");
          }
        });
      },
      { threshold: 0.5, rootMargin: "-20% 0px -55% 0px" }
    );
    Object.keys(sectionMap).forEach(function (hash) {
      spy.observe(sectionMap[hash].el);
    });
  }
})();
