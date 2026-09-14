/**
 * The og:image card, composed from `design/armada-icon.svg` rather than drawn
 * beside it.
 *
 * bastion and cupertino compose theirs with `composeCard` in their repo-root
 * `scripts/lib/lockup.mjs`, which also writes the README banner. Armada has no
 * lockup yet (design/README.md: "If one is ever needed, this is where it goes"), so
 * this smaller composer lives beside the one script that uses it. When a lockup
 * module lands at the root, move this there rather than growing a twin.
 *
 * It is a vertical stack, not the siblings' horizontal lockup, for a mechanical
 * reason: centring icon and word as one block needs the word's rendered width,
 * which the siblings get from a CoreText measurement typed into their module.
 * Stacked and centred with `text-anchor="middle"`, nothing here needs measuring.
 *
 * Nothing is redrawn. The sails, the water, the plate and the squircle all come
 * from the embedded icon; the only numbers here are layout.
 *
 * Baked, not served: `pnpm icons` renders this to PNG on the machine that runs it,
 * so the typeface resolves there. That is safe only because it runs on a Mac.
 * Rendered on Linux, the system stack would silently fall back to another font.
 */

const CARD = { WIDTH: 1200, HEIGHT: 630, SAFE_INSET: 60 };

/**
 * Layout, top to bottom. X renders `summary_large_image` at 2:1 while og:image is
 * 1.91:1, so roughly 15px comes off the top and bottom; SAFE_INSET keeps every
 * mark well clear of that band, and `composeCard` throws rather than crossing it.
 */
const ICON = 148;
const ICON_Y = 104;
const WORD = 76;
const WORD_Y = 340;
const HEADLINE = 40;
const HEADLINE_Y = 436;
const SUBHEAD = 27;
const SUBHEAD_Y = 490;

/** The card's own ground: the page background, ramped, as bastion's card is. */
const GROUND = ["#15161b", "#08090b"];

const FONT_STACK =
  '-apple-system, BlinkMacSystemFont, "SF Pro Display", "Helvetica Neue", Helvetica, Arial, sans-serif';

/** Throws rather than passing the artwork through: every check guards a silent failure. */
const expect = (condition, message) => {
  if (!condition) throw new Error(`armada social card: ${message}`);
};

const escapeXml = (text) =>
  text.replace(
    /[&<>"]/g,
    (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[char],
  );

/** Everything between the root `<svg>` tag and its close. One known generated file. */
const bodyOf = (svg) => {
  const match = /<svg\b[^>]*>([\s\S]*)<\/svg>\s*$/.exec(svg);
  expect(match, "the icon does not look like an SVG document");
  return match[1];
};

/**
 * Renames every id in the embedded icon and every `url(#…)` pointing at one. The
 * icon ships ids as generic as `c` and `sky`, and it is about to share an id space
 * with the card's own gradients.
 */
const namespaceIds = (body, prefix) => {
  const ids = [...body.matchAll(/\bid="([^"]+)"/g)].map((match) => match[1]);
  expect(ids.length > 0, "the icon defines no ids; has its structure changed?");
  return ids.reduce(
    (text, id) =>
      text
        .replaceAll(`id="${id}"`, `id="${prefix}${id}"`)
        .replaceAll(`url(#${id})`, `url(#${prefix}${id})`),
    body,
  );
};

const viewBoxOf = (svg) => {
  const match = /\bviewBox="0 0 (\d+(?:\.\d+)?) (\d+(?:\.\d+)?)"/.exec(svg);
  expect(match, 'the icon has no `viewBox="0 0 w h"` to scale from');
  const [width, height] = [Number(match[1]), Number(match[2])];
  expect(width === height, `the icon is not square (${width}×${height})`);
  return width;
};

const line = ({ text, y, size, fill, weight, opacity }) =>
  `  <text x="${CARD.WIDTH / 2}" y="${y}" fill="${fill}"${
    opacity ? ` opacity="${opacity}"` : ""
  } text-anchor="middle"
        font-family='${FONT_STACK}' font-size="${size}" font-weight="${weight}">${escapeXml(text)}</text>`;

/**
 * @param {string} iconSvg contents of `design/armada-icon.svg`
 * @param {object} palette parsed `design/colors.json`
 * @param {{ headline: string, subhead: string, width: number, height: number }} copy
 * @returns {string} the card SVG, for sharp to rasterise
 */
export const composeCard = (iconSvg, palette, { headline, subhead, width, height }) => {
  expect(
    width === CARD.WIDTH && height === CARD.HEIGHT,
    `config says ${width}×${height}, the composer draws ${CARD.WIDTH}×${CARD.HEIGHT}`,
  );
  expect(headline && subhead, "the card needs both a headline and a subhead");

  const sail = palette?.colors?.sail;
  const glow = palette?.colors?.plateBottom;
  expect(sail, "colors.json has no `colors.sail` to set the words in");
  expect(glow, "colors.json has no `colors.plateBottom` for the glow");

  const lowest = SUBHEAD_Y + SUBHEAD * 0.25;
  expect(ICON_Y >= CARD.SAFE_INSET, "the icon sits inside the band X crops away");
  expect(
    lowest <= CARD.HEIGHT - CARD.SAFE_INSET,
    `the subhead reaches ${Math.round(lowest)}, inside the band X crops away`,
  );

  const source = viewBoxOf(iconSvg);
  const body = namespaceIds(bodyOf(iconSvg), "icon-")
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/<title>[\s\S]*?<\/title>/g, "")
    .replace(/^\s*\n/gm, "")
    .trim();
  expect(body.includes("clip-path"), "the icon body lost its clip; is it the generated file?");

  const iconX = (CARD.WIDTH - ICON) / 2;

  return `<svg xmlns="http://www.w3.org/2000/svg" width="${CARD.WIDTH}" height="${CARD.HEIGHT}"
     viewBox="0 0 ${CARD.WIDTH} ${CARD.HEIGHT}" role="img" aria-label="Armada">
  <!-- GENERATED by apps/website/scripts/generate-icons.mjs — do not edit. -->
  <defs>
    <linearGradient id="ground" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="0" y2="${CARD.HEIGHT}">
      <stop offset="0" stop-color="${GROUND[0]}"/>
      <stop offset="1" stop-color="${GROUND[1]}"/>
    </linearGradient>
    <radialGradient id="glow" gradientUnits="userSpaceOnUse" cx="${CARD.WIDTH / 2}" cy="${ICON_Y + ICON / 2}" r="560">
      <stop offset="0" stop-color="${glow}" stop-opacity="0.26"/>
      <stop offset="0.55" stop-color="${glow}" stop-opacity="0.05"/>
      <stop offset="1" stop-color="${glow}" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect width="${CARD.WIDTH}" height="${CARD.HEIGHT}" fill="url(#ground)"/>
  <rect width="${CARD.WIDTH}" height="${CARD.HEIGHT}" fill="url(#glow)"/>
  <g transform="translate(${iconX} ${ICON_Y}) scale(${ICON / source})">
${body}
  </g>
${line({ text: "Armada", y: WORD_Y, size: WORD, fill: sail, weight: 600 })}
${line({ text: headline, y: HEADLINE_Y, size: HEADLINE, fill: sail, weight: 500 })}
${line({ text: subhead, y: SUBHEAD_Y, size: SUBHEAD, fill: sail, weight: 400, opacity: "0.62" })}
</svg>
`;
};
