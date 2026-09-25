package local.webhtv.phase0;

public final class Main {
    private Main() {}

    public static void main(String[] args) {
        try (LibMpv player = new LibMpv()) {
            System.out.println("libmpv client api: " + player.clientVersion());
            if (args.length > 0) {
                String url = args[0];
                String referer = args.length > 1 ? args[1] : "";
                String userAgent = args.length > 2 ? args[2] : "WebHTV-PC-Phase0";
                if ("--config-flow".equals(args[0])) {
                    if (args.length < 2) throw new IllegalArgumentException("--config-flow 需要配置文件路径");
                    try {
                        HttpApiFlow.PlaybackRequest request = new HttpApiFlow().resolve(java.nio.file.Path.of(args[1]));
                        url = request.url();
                        referer = request.referer();
                        userAgent = request.userAgent();
                    } catch (java.io.IOException | InterruptedException error) {
                        if (error instanceof InterruptedException) {
                            Thread.currentThread().interrupt();
                        }
                        throw new IllegalStateException("HTTP API 配置播放闭环失败", error);
                    }
                }
                System.out.printf("playback-request url=%s referer=%s user-agent=%s%n", url, referer, userAgent);
                player.load(url, referer, userAgent);
                String result = player.waitForPlaybackResult(20.0);
                System.out.println(result);
                if (result.startsWith("error:") || result.equals("timeout")) {
                    throw new IllegalStateException("播放验证失败：" + result);
                }
                if (!"--config-flow".equals(args[0]) && args.length > 3) {
                    double seekSeconds = Double.parseDouble(args[3]);
                    player.seek(seekSeconds);
                    try {
                        Thread.sleep(1000L);
                    } catch (InterruptedException error) {
                        Thread.currentThread().interrupt();
                        throw new IllegalStateException("Seek 验证等待被中断", error);
                    }
                    double actualSeconds = player.playbackTime();
                    System.out.printf("seek-target=%.3f playback-time=%.3f%n", seekSeconds, actualSeconds);
                    if (actualSeconds < seekSeconds - 0.75) {
                        throw new IllegalStateException("Seek 验证失败：" + actualSeconds);
                    }
                }
            }
        }
    }
}
