class HomeHeroArtEvidence {
  const HomeHeroArtEvidence({required this.width, required this.height});

  final int width;
  final int height;

  bool get isEligible => width >= 1280 && height >= 720 && width > height;
}
