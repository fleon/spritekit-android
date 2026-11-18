package com.spritekit.platform.billing;

import android.app.Activity;
import android.util.Base64;
import android.util.Log;

import com.android.billingclient.api.AcknowledgePurchaseParams;
import com.android.billingclient.api.BillingClient;
import com.android.billingclient.api.BillingClientStateListener;
import com.android.billingclient.api.BillingFlowParams;
import com.android.billingclient.api.BillingResult;
import com.android.billingclient.api.ConsumeParams;
import com.android.billingclient.api.PendingPurchasesParams;
import com.android.billingclient.api.ProductDetails;
import com.android.billingclient.api.Purchase;
import com.android.billingclient.api.QueryProductDetailsParams;
import com.android.billingclient.api.QueryPurchasesParams;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import com.spritekit.platform.PlatformService;
import com.spritekit.platform.PlatformServices;

import java.security.KeyFactory;
import java.security.PublicKey;
import java.security.Signature;
import java.security.spec.X509EncodedKeySpec;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Play Billing for one-time products: their prices, buying one (pending and
 * cancelled included), acknowledging it and handing back what is owned. A
 * consumable is consumed once the game has granted it ({@code consume},
 * answered by {@code consumed {code, token}}), and each purchase reports its
 * {@code quantity}: the runtime README's "Consumables: what the app's Java
 * answers".
 *
 * <p>The decisions — what is owned, when, whether a purchase finished — are
 * Swift's ({@code PlayBilling} in PlatformShim, tested on the Mac). This
 * class only speaks to the Billing Library and reports, in events:
 *
 * <ul>
 *   <li>{@code product}: a product's localized price.</li>
 *   <li>{@code owned}: every one-time purchase Play holds for the player,
 *       after a query ({@code ok} false when the query failed, so a
 *       network error never reads as a refund).</li>
 *   <li>{@code updated}: the result of a purchase flow, or a purchase that
 *       changed while the app runs (a pending one completing).</li>
 *   <li>{@code acknowledged}, {@code consumed}, {@code unavailable}.</li>
 * </ul>
 *
 * <p>Added by a game that sells something, in
 * {@code SpriteKitActivity.addServices}:
 * {@code services.add(PlayBilling.SERVICE, new PlayBilling(this, services))}.
 */
public final class PlayBilling implements PlatformService {
    public static final String SERVICE = "billing";

    private final Activity activity;
    private final PlatformServices services;
    private final BillingClient client;
    private final String licenseKey;
    private final List<String> productIds = new ArrayList<>();
    private final Map<String, ProductDetails> details = new HashMap<>();
    private boolean connecting;

    public PlayBilling(Activity activity, PlatformServices services) {
        this.activity = activity;
        this.services = services;
        licenseKey = activity.getString(R.string.play_license_key);
        client = BillingClient.newBuilder(activity)
            .setListener(this::onPurchasesUpdated)
            .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().build())
            .enableAutoServiceReconnection()
            .build();
    }

    @Override
    public JSONObject call(String method, JSONObject args) throws JSONException {
        switch (method) {
            case "start": {
                JSONArray ids = args.optJSONArray("products");
                synchronized (productIds) {
                    productIds.clear();
                    for (int i = 0; ids != null && i < ids.length(); i++) productIds.add(ids.getString(i));
                }
                activity.runOnUiThread(this::connect);
                return null;
            }
            case "purchase": {
                String productId = args.getString("productId");
                activity.runOnUiThread(() -> launch(productId));
                return null;
            }
            case "restore":
                activity.runOnUiThread(this::queryPurchases);
                return null;
            case "acknowledge": {
                String token = args.getString("token");
                activity.runOnUiThread(() -> acknowledge(token));
                return null;
            }
            case "consume": {
                String token = args.getString("token");
                activity.runOnUiThread(() -> consume(token));
                return null;
            }
            default:
                Log.w(PlatformServices.tag(), "no billing." + method);
                return null;
        }
    }

    @Override
    public void onResume() {
        // A pending purchase can complete while the game is away (paid in
        // cash at a shop): Google asks apps to look again on resume.
        if (client.isReady()) queryPurchases();
    }

    @Override
    public void onDestroy() {
        client.endConnection();
    }

    private void connect() {
        if (client.isReady()) {
            queryProducts();
            queryPurchases();
            return;
        }
        if (connecting) return;
        connecting = true;
        client.startConnection(new BillingClientStateListener() {
            @Override
            public void onBillingSetupFinished(BillingResult result) {
                activity.runOnUiThread(() -> {
                    connecting = false;
                    if (result.getResponseCode() == BillingClient.BillingResponseCode.OK) {
                        queryProducts();
                        queryPurchases();
                    } else {
                        Log.w(PlatformServices.tag(), "billing unavailable: " + result.getDebugMessage());
                        services.post(SERVICE, "unavailable", result(result));
                    }
                });
            }

            @Override
            public void onBillingServiceDisconnected() {
                // enableAutoServiceReconnection reconnects on the next call.
                connecting = false;
            }
        });
    }

    private void queryProducts() {
        List<QueryProductDetailsParams.Product> products = new ArrayList<>();
        synchronized (productIds) {
            for (String id : productIds) {
                products.add(QueryProductDetailsParams.Product.newBuilder()
                    .setProductId(id)
                    .setProductType(BillingClient.ProductType.INAPP)
                    .build());
            }
        }
        if (products.isEmpty()) return;
        client.queryProductDetailsAsync(
            QueryProductDetailsParams.newBuilder().setProductList(products).build(),
            (result, found) -> activity.runOnUiThread(() -> {
                if (result.getResponseCode() != BillingClient.BillingResponseCode.OK) {
                    Log.w(PlatformServices.tag(), "product details: " + result.getDebugMessage());
                    return;
                }
                for (ProductDetails product : found.getProductDetailsList()) {
                    details.put(product.getProductId(), product);
                    ProductDetails.OneTimePurchaseOfferDetails offer = product.getOneTimePurchaseOfferDetails();
                    if (offer == null) continue;
                    services.post(SERVICE, "product", PlatformServices.object(
                        "productId", product.getProductId(),
                        "price", offer.getFormattedPrice(),
                        "priceMicros", offer.getPriceAmountMicros(),
                        "currency", offer.getPriceCurrencyCode()));
                }
                if (!found.getUnfetchedProductList().isEmpty()) {
                    Log.w(PlatformServices.tag(), found.getUnfetchedProductList().size() + " product(s) not found on Play");
                }
            }));
    }

    private void queryPurchases() {
        client.queryPurchasesAsync(
            QueryPurchasesParams.newBuilder().setProductType(BillingClient.ProductType.INAPP).build(),
            (result, purchases) -> {
                JSONObject body = result(result);
                put(body, "purchases", describe(purchases));
                services.post(SERVICE, "owned", body);
            });
    }

    private void launch(String productId) {
        ProductDetails product = details.get(productId);
        if (!client.isReady() || product == null) {
            // Not connected yet, or Play doesn't know the product: say so
            // rather than leave the game's offer spinning.
            services.post(SERVICE, "updated", PlatformServices.object(
                "code", client.isReady() ? "error" : "unavailable", "responseCode", -1, "productId", productId));
            if (!client.isReady()) connect();
            return;
        }
        List<BillingFlowParams.ProductDetailsParams> params = new ArrayList<>();
        params.add(BillingFlowParams.ProductDetailsParams.newBuilder().setProductDetails(product).build());
        BillingResult result = client.launchBillingFlow(activity,
            BillingFlowParams.newBuilder().setProductDetailsParamsList(params).build());
        if (result.getResponseCode() != BillingClient.BillingResponseCode.OK) {
            JSONObject body = result(result);
            put(body, "productId", productId);
            services.post(SERVICE, "updated", body);
        }
    }

    private void acknowledge(String token) {
        client.acknowledgePurchase(
            AcknowledgePurchaseParams.newBuilder().setPurchaseToken(token).build(),
            result -> {
                JSONObject body = result(result);
                put(body, "token", token);
                services.post(SERVICE, "acknowledged", body);
            });
    }

    /** Uses up a consumable once the game has granted it, so it can be bought again. */
    private void consume(String token) {
        client.consumeAsync(
            ConsumeParams.newBuilder().setPurchaseToken(token).build(),
            (result, consumedToken) -> {
                JSONObject body = result(result);
                put(body, "token", token);
                services.post(SERVICE, "consumed", body);
            });
    }

    /** The end of a purchase flow, and any purchase that changes meanwhile. */
    private void onPurchasesUpdated(BillingResult result, List<Purchase> purchases) {
        JSONObject body = result(result);
        put(body, "purchases", describe(purchases));
        services.post(SERVICE, "updated", body);
    }

    private JSONArray describe(List<Purchase> purchases) {
        JSONArray list = new JSONArray();
        if (purchases == null) return list;
        for (Purchase purchase : purchases) {
            if (!isGenuine(purchase)) {
                Log.w(PlatformServices.tag(), "dropping a purchase whose signature does not verify");
                continue;
            }
            String state;
            switch (purchase.getPurchaseState()) {
                case Purchase.PurchaseState.PURCHASED: state = "purchased"; break;
                case Purchase.PurchaseState.PENDING: state = "pending"; break;
                default: state = "unspecified";
            }
            list.put(PlatformServices.object(
                "products", new JSONArray(purchase.getProducts()),
                "state", state,
                "token", purchase.getPurchaseToken(),
                "time", purchase.getPurchaseTime(),
                "acknowledged", purchase.isAcknowledged(),
                "quantity", purchase.getQuantity()));
        }
        return list;
    }

    /**
     * Checks Play's signature over the purchase with the app's licence key
     * (Play Console → Monetization setup), when the build carries one
     * (the {@code play_license_key} string, which the app's build sets from
     * {@code -Pgame.playLicenseKey=…}). Without a server this is the check
     * there is; without a key every purchase is taken as Play reports it.
     */
    private boolean isGenuine(Purchase purchase) {
        String key = licenseKey;
        if (key == null || key.isEmpty()) return true;
        try {
            PublicKey publicKey = KeyFactory.getInstance("RSA")
                .generatePublic(new X509EncodedKeySpec(Base64.decode(key, Base64.DEFAULT)));
            Signature signature = Signature.getInstance("SHA1withRSA");
            signature.initVerify(publicKey);
            signature.update(purchase.getOriginalJson().getBytes("UTF-8"));
            return signature.verify(Base64.decode(purchase.getSignature(), Base64.DEFAULT));
        } catch (Exception e) {
            Log.e(PlatformServices.tag(), "could not verify a purchase", e);
            return false;
        }
    }

    private static JSONObject result(BillingResult result) {
        String code;
        switch (result.getResponseCode()) {
            case BillingClient.BillingResponseCode.OK: code = "ok"; break;
            case BillingClient.BillingResponseCode.USER_CANCELED: code = "cancelled"; break;
            case BillingClient.BillingResponseCode.ITEM_ALREADY_OWNED: code = "owned"; break;
            case BillingClient.BillingResponseCode.SERVICE_DISCONNECTED:
            case BillingClient.BillingResponseCode.SERVICE_UNAVAILABLE:
            case BillingClient.BillingResponseCode.BILLING_UNAVAILABLE:
            case BillingClient.BillingResponseCode.NETWORK_ERROR: code = "unavailable"; break;
            default: code = "error";
        }
        return PlatformServices.object("code", code, "responseCode", result.getResponseCode(),
            "message", result.getDebugMessage());
    }

    private static void put(JSONObject object, String key, Object value) {
        try {
            object.put(key, value);
        } catch (JSONException e) {
            Log.e(PlatformServices.tag(), "bad billing event", e);
        }
    }
}
