/// The public page where a customer claims a cheque. It follows the Balkans
/// sign-in screen: dark field, name on the left, phone card on the right.
String offerPageHtml() => '''
<!DOCTYPE html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Balkans</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; min-height: 100vh; min-height: 100dvh;
    background:
      radial-gradient(80vw 42vh at 8% -8%, rgba(226,93,52,.55), transparent 62%),
      radial-gradient(70vw 40vh at 110% 110%, rgba(154,43,43,.4), transparent 58%),
      #141414;
    color: #f4f4f4;
    font-family: "Segoe UI", Tahoma, sans-serif;
  }
  .stage {
    min-height: 100vh; min-height: 100dvh;
    display: flex; align-items: center; justify-content: center;
    gap: 64px; padding: 28px 20px;
  }
  .brand { max-width: 360px; text-align: center; }
  .logo {
    width: 168px; height: 168px; object-fit: contain;
    background: #fff; border-radius: 28px; padding: 10px;
  }
  .brand p { margin: 16px 0 0; color: #e4e4e4; font-size: 18px; line-height: 1.45; }
  .card {
    width: min(440px, 100%);
    background: #2a2a2a;
    border: 1px solid #3a3a3a;
    border-radius: 22px;
    padding: 28px 26px 24px;
    box-shadow: 0 20px 60px rgba(0,0,0,.35);
  }
  h2 { margin: 0 0 8px; font-size: 28px; }
  .lead { margin: 0 0 18px; color: #c8c8c8; line-height: 1.4; }
  label { display: block; margin: 14px 0 8px; color: #ddd; }
  .phone { display: flex; gap: 8px; }
  .cc, input {
    background: #1f1f1f; color: #fff; border: 1px solid #4a4a4a;
    border-radius: 14px; padding: 14px 12px; font-size: 16px;
  }
  .cc { width: 92px; display: flex; align-items: center; justify-content: center; gap: 6px; }
  input { flex: 1; outline: none; }
  input:focus, .cc { border-color: #6a6a6a; }
  button {
    width: 100%; margin-top: 22px; border: 0; border-radius: 12px;
    background: #9a2b2b; color: #fff; font-weight: 700; letter-spacing: .04em;
    padding: 14px; font-size: 16px; cursor: pointer;
  }
  button.ghost { background: #fff; color: #1a1a1a; }
  button:disabled { opacity: .6; cursor: default; }
  .err { color: #ffb4b4; min-height: 1.2em; margin: 10px 0 0; }
  .cheque { display: none; }
  .cheque img.art { width: min(920px, 100%); border-radius: 18px; display: block; }
  .frame { position: relative; display: inline-block; max-width: 100%; }
  .serial {
    position: absolute; left: 2.1%; top: 3.8%;
    width: 18.6%; height: 6.3%;
    background: #e25d34; color: #fff;
    display: flex; align-items: center; padding-left: 1.2%;
    font-weight: 650; font-size: clamp(8px, 1.35vw, 14px);
    letter-spacing: .02em; white-space: nowrap;
  }
  .hint { text-align: center; color: #ddd; margin: 14px 0 0; }
  .save { max-width: 920px; }
  @media (max-width: 800px) {
    .stage { flex-direction: column; align-items: stretch; gap: 22px; padding: 22px 16px 28px; }
    .brand, .card, .save { width: 100%; max-width: none; }
    .logo { width: 132px; height: 132px; }
    .brand p { font-size: 16px; }
    .frame { display: block; }
    .cheque img.art { width: 100%; }
  }
</style></head>
<body>
<div class="stage" id="claim">
  <div class="brand">
    <img class="logo" src="/offer/logo.png" alt="Balkan's">
    <p>Order your favourite food — fast, fresh, and delivered to your door.</p>
  </div>
  <form class="card" id="form">
    <h2>Here's your credit</h2>
    <p class="lead">Enter your phone number and take the offer to any branch.</p>
    <label for="phone">Phone number</label>
    <div class="phone">
      <div class="cc">EG +20</div>
      <input id="phone" inputmode="tel" autocomplete="tel" placeholder="100 123 4567" autofocus required>
    </div>
    <p class="err" id="err"></p>
    <button id="go" type="submit">GET THE OFFER</button>
  </form>
</div>
<div class="stage cheque" id="result">
  <div>
    <div class="frame">
      <img class="art" src="/offer/cheque.jpg" alt="The Balkans cheque">
      <div class="serial" id="serial"></div>
    </div>
    <p class="hint" id="hint"></p>
    <button class="ghost save" id="save" type="button">SAVE THE CHEQUE</button>
  </div>
</div>
<script>
const messages = {
  name: 'Enter a real mobile number.',
  used: 'This number already used the offer.',
  empty: 'There are no offers left.',
  expired: 'This offer has ended.',
  server: 'The offer could not be created. Try again.'
};
document.getElementById('form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const button = document.getElementById('go');
  const err = document.getElementById('err');
  err.textContent = '';
  button.disabled = true;
  try {
    const res = await fetch('/v1/offer', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ phone: document.getElementById('phone').value })
    });
    const body = await res.json();
    if (!body.ok) {
      err.textContent = messages[body.error] || messages.server;
      button.disabled = false;
      return;
    }
    document.getElementById('serial').textContent = 'Serial Number ' + String(body.serial).padStart(10, '0');
    document.getElementById('hint').textContent =
      body.percent + '% off  ·  show this at the branch  ·  valid until ' + body.expires;
    document.getElementById('claim').style.display = 'none';
    document.getElementById('result').style.display = 'flex';
  } catch (e) {
    err.textContent = messages.server;
    button.disabled = false;
  }
});
document.getElementById('save').addEventListener('click', saveCheque);
async function saveCheque() {
  const art = document.querySelector('.art');
  const canvas = document.createElement('canvas');
  canvas.width = 1024;
  canvas.height = 477;
  const ctx = canvas.getContext('2d');
  ctx.drawImage(art, 0, 0, 1024, 477);
  ctx.fillStyle = '#e25d34';
  ctx.fillRect(22, 18, 188, 28);
  ctx.fillStyle = '#fff';
  ctx.font = '600 15px Segoe UI, sans-serif';
  ctx.textBaseline = 'middle';
  ctx.fillText(document.getElementById('serial').textContent, 30, 32);
  const blob = await new Promise((resolve) => canvas.toBlob(resolve, 'image/jpeg', 0.92));
  const file = new File([blob], 'balkans-cheque.jpg', { type: 'image/jpeg' });
  if (navigator.canShare && navigator.canShare({ files: [file] })) {
    await navigator.share({ files: [file], title: "Balkan's cheque" });
    return;
  }
  const link = document.createElement('a');
  link.href = URL.createObjectURL(blob);
  link.download = 'balkans-cheque.jpg';
  link.click();
}
</script>
</body></html>
''';
