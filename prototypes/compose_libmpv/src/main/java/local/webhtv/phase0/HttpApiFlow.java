package local.webhtv.phase0;

import com.google.gson.Gson;
import com.google.gson.JsonArray;
import com.google.gson.JsonObject;
import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;

public final class HttpApiFlow {
    private static final Gson GSON = new Gson();
    private final HttpClient client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(2)).build();

    public PlaybackRequest resolve(Path configPath) throws IOException, InterruptedException {
        JsonObject config = GSON.fromJson(Files.readString(configPath, StandardCharsets.UTF_8), JsonObject.class);
        JsonArray sites = config.getAsJsonArray("sites");
        if (sites == null || sites.isEmpty()) throw new IllegalStateException("配置中没有 sites");
        JsonObject site = sites.get(0).getAsJsonObject();
        String api = requiredString(site, "api");

        JsonObject home = getJson(api);
        requireNonEmptyArray(home, "class", "首页分类");
        requireNonEmptyArray(home, "list", "首页列表");

        JsonObject category = getJson(api + "?ac=category");
        JsonObject categoryVod = firstObject(category, "list", "分类列表");
        String vodId = requiredString(categoryVod, "vod_id");

        JsonObject detail = getJson(api + "?ac=detail&ids=" + vodId);
        JsonObject detailVod = firstObject(detail, "list", "详情列表");
        String playUrl = requiredString(detailVod, "vod_play_url");
        if (!playUrl.contains("$")) throw new IllegalStateException("详情播放地址缺少剧集分隔符");

        JsonObject play = getJson(api + "?ac=play&id=" + vodId);
        String url = requiredString(play, "url");
        JsonObject header = play.getAsJsonObject("header");
        String referer = header == null ? "" : optionalString(header, "Referer");
        String userAgent = header == null ? "WebHTV-PC-Phase0" : optionalString(header, "User-Agent");
        System.out.printf("http-api-flow site=%s vod=%s url=%s%n", requiredString(site, "key"), vodId, url);
        return new PlaybackRequest(url, referer, userAgent);
    }

    private JsonObject getJson(String url) throws IOException, InterruptedException {
        HttpRequest request = HttpRequest.newBuilder(URI.create(url)).timeout(Duration.ofSeconds(3)).GET().build();
        HttpResponse<String> response = client.send(request, HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
        if (response.statusCode() != 200) throw new IllegalStateException("HTTP API 返回状态码 " + response.statusCode());
        return GSON.fromJson(response.body(), JsonObject.class);
    }

    private static JsonObject firstObject(JsonObject object, String field, String label) {
        JsonArray values = requireNonEmptyArray(object, field, label);
        return values.get(0).getAsJsonObject();
    }

    private static JsonArray requireNonEmptyArray(JsonObject object, String field, String label) {
        JsonArray values = object.getAsJsonArray(field);
        if (values == null || values.isEmpty()) throw new IllegalStateException(label + "为空");
        return values;
    }

    private static String requiredString(JsonObject object, String field) {
        String value = optionalString(object, field);
        if (value.isBlank()) throw new IllegalStateException("缺少必填字段：" + field);
        return value;
    }

    private static String optionalString(JsonObject object, String field) {
        return object.has(field) && !object.get(field).isJsonNull() ? object.get(field).getAsString() : "";
    }

    public record PlaybackRequest(String url, String referer, String userAgent) {}
}
