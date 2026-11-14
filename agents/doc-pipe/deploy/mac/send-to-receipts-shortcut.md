# "Send to Receipts" – iPhone Shortcut

Pick receipt photos in the Photos app, tap Share, tap **Send to Receipts**. Each photo goes straight into the receipts page on Alexus. That's the same as using "Choose photos" on the page: exact copies are skipped, possible duplicates get flagged, and odd dates get a 📅 check-date flag.

**Before you start:** Tailscale must be on on the iPhone. The address below only works over Tailscale, which also encrypts the connection.

## Build it (one time, about 5 minutes)

1. Open the **Shortcuts** app. Tap **+** (top right). At the top, rename it to **Send to Receipts**.
2. Tap the **ⓘ** (or the name at the top, then **Details**). Turn on **Show in Share Sheet**. Then tap **Share Sheet Types**, turn everything off except **Images**, and tap Done.
   The first action now reads **"Receive Images from Share Sheet"**. Tap "If there's no input" and choose **Stop and Respond**.
3. **Your login (typed by you, only on your phone)**
   - Add the action **Text**.
   - In the box, type `chris:` and then your receipts-page password right after the colon, with no spaces. Use the same login you use for the receipts page.
4. Add the action **Base64 Encode**. It should say "Base64 Encode *Text*".
   Tap the small arrow on it and set **Line Breaks** to **None**.
5. Add the action **Set Variable**. Name the variable `Login`. The input should be the **Base64 Encoded** result.
6. Add the action **Repeat with Each**. The item should be **Shortcut Input**.
   Put the next two actions inside the repeat block, between "Repeat with Each" and "End Repeat".
7. **Inside the repeat:** add the action **Convert Image**, and set it to "Convert *Repeat Item* to **JPEG**". This turns iPhone HEIC photos into JPEG.
8. **Inside the repeat:** add the action **Get Contents of URL**.
   - URL:
     `http://alexus:8448/api/upload-raw?filename=receipt.jpg`
   - Tap the arrow on the action to show the options.
   - **Method:** POST
   - **Headers:** tap **Add new header** twice.
     - First header: key `Authorization`, value `Basic `. Type "Basic" and one space, then tap the variable bar and insert the **Login** variable.
     - Second header: key `Content-Type`, value `image/jpeg`.
   - **Request Body:** **File**. Choose **Converted Image** as the file.
9. Below **End Repeat**, add the action **Show Notification**. Type: `Sent to Receipts ✅`.
10. Tap **Done**.

## Use it

- **Photos:** select one or many receipt photos, tap **Share**, then **Send to Receipts**.
- **First time only:** iOS asks whether "Send to Receipts" may connect to alexus. Tap **Always Allow**.
- **Afterwards:** open or reload the receipts page. New receipts show up as "processing" and are ready in about a minute each.

## If something goes wrong

- **"401" or "not authorised":** the password in step 3 is wrong. Open the shortcut and fix the Text action.
- **"Could not connect" or a timeout:** turn Tailscale on and try again.
- **"415":** the photo wasn't converted. Make sure step 7 is inside the repeat and set to JPEG.
- **PDFs** aren't supported yet. Take a screenshot of the PDF and share that instead.

## Keep your password private

Your password lives only inside this shortcut on your phone. Don't use **Share** on the shortcut itself, because that would send the password along with it. If you ever change the receipts password, update step 3.

## Other ways in (no phone needed)

- **On the Mac:** drop photos into the **Receipts-Inbox** folder in your home folder (Finder → Go → Home). Within about a minute they're sent to Alexus, and the originals move to **Receipts-Inbox/sent**. Nothing is deleted.
- **On Alexus:** files put in `~/receipts-inbox` are picked up every minute and moved to `done/`. Anything that couldn't be read goes to `failed/`, with a `.reason.txt` file next to it explaining why.
