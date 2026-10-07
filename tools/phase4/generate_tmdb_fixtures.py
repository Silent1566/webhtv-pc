#!/usr/bin/env python3
"""生成 Phase 4 TMDB fixture（docs/phase4/design/05 §2.1）。

只写 fixture，不参与运行时代码。重复执行结果幂等。
"""

import json
import os

BASE = os.path.join("packages", "test-fixtures", "tmdb")


def write(name, obj):
    path = os.path.join(BASE, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as stream:
        json.dump(obj, stream, ensure_ascii=False, indent=2)
        stream.write("\n")


write("configuration.json", {
    "images": {
        "base_url": "http://image.tmdb.org/t/p/",
        "secure_base_url": "https://image.tmdb.org/t/p/",
        "poster_sizes": ["w92", "w154", "w185", "w342", "w500", "w780", "original"],
        "backdrop_sizes": ["w300", "w780", "w1280", "original"],
    },
    "change_keys": ["adult", "images", "overview"],
})

TV_ITEM = {
    "id": 1399, "media_type": "tv", "name": "示例剧集", "original_name": "Fixture Show",
    "overview": "示例剧集简介", "poster_path": "/tv-poster.jpg", "backdrop_path": "/tv-backdrop.jpg",
    "first_air_date": "2024-03-01", "vote_average": 8.2, "original_language": "zh",
    "origin_country": ["CN"], "genre_ids": [18, 10765],
}
MOVIE_ITEM = {
    "id": 550, "media_type": "movie", "title": "示例电影", "original_title": "Fixture Movie",
    "overview": "示例电影简介", "poster_path": "/movie-poster.jpg", "backdrop_path": "/movie-backdrop.jpg",
    "release_date": "2023-06-15", "vote_average": 7.9, "original_language": "en",
    "origin_country": ["US"], "genre_ids": [28],
}
PERSON_ITEM = {
    "id": 287, "media_type": "person", "name": "示例演员", "profile_path": "/person.jpg",
    "known_for_department": "Acting",
}
SPLIT_ITEM = {
    "id": 900001, "media_type": "tv", "name": "示例剧集 分季版", "original_name": "Fixture Show Split",
    "overview": "分季版", "poster_path": "/split-poster.jpg", "backdrop_path": "/split-backdrop.jpg",
    "first_air_date": "2024-03-01", "vote_average": 6.1, "original_language": "zh",
    "origin_country": ["CN"], "genre_ids": [18],
}

write("search-multi.json", {"page": 1, "total_pages": 1, "total_results": 3,
                            "results": [TV_ITEM, MOVIE_ITEM, PERSON_ITEM]})
write("search-empty.json", {"page": 1, "total_pages": 1, "total_results": 0, "results": []})
write("search-split-season.json", {"page": 1, "total_pages": 1, "total_results": 2,
                                   "results": [SPLIT_ITEM, TV_ITEM]})


def seasons():
    return [
        {"season_number": 0, "name": "特别篇", "episode_count": 3, "air_date": "2021-01-10",
         "poster_path": "/s0.jpg", "overview": "特别篇"},
        {"season_number": 1, "name": "第 1 季", "episode_count": 12, "air_date": "2024-03-01",
         "poster_path": "/s1.jpg", "overview": "第 1 季"},
        {"season_number": 2, "name": "第 2 季", "episode_count": 10, "air_date": "2025-04-05",
         "poster_path": "/s2.jpg", "overview": "第 2 季"},
    ]


def credits():
    return {
        "cast": [{"id": 287, "name": "示例演员", "character": "主角", "profile_path": "/person.jpg",
                  "known_for_department": "Acting", "order": 0}],
        "crew": [{"id": 500, "name": "示例导演", "job": "Director", "department": "Directing",
                  "profile_path": "/crew.jpg"}],
    }


def detail(next_air=False):
    payload = {
        "id": 1399, "name": "示例剧集", "original_name": "Fixture Show", "overview": "示例剧集简介",
        "poster_path": "/tv-poster.jpg", "backdrop_path": "/tv-backdrop.jpg",
        "first_air_date": "2024-03-01", "vote_average": 8.2, "original_language": "zh",
        "origin_country": ["CN"], "genres": [{"id": 18, "name": "剧情"}, {"id": 10765, "name": "科幻"}],
        "seasons": seasons(), "credits": credits(),
        "aggregate_credits": {
            "cast": [{"id": 287, "name": "示例演员",
                      "roles": [{"character": "主角", "episode_count": 12}],
                      "profile_path": "/person.jpg"}],
        },
        "created_by": [{"id": 500, "name": "示例导演", "profile_path": "/crew.jpg"}],
        "translations": {
            "translations": [
                {"iso_639_1": "zh", "iso_3166_1": "CN",
                 "data": {"overview": "示例剧集简介（中文翻译版，长度更长以便验证替换规则）"}},
            ],
        },
        "images": {
            "posters": [
                {"file_path": "/p1.jpg", "width": 680, "height": 1020,
                 "vote_average": 5.6, "vote_count": 12},
                {"file_path": "/p2.jpg", "width": 342, "height": 513,
                 "vote_average": 5.6, "vote_count": 3},
            ],
            "backdrops": [
                {"file_path": "/b1.jpg", "width": 1920, "height": 1080,
                 "vote_average": 5.4, "vote_count": 8},
            ],
        },
        "external_ids": {"imdb_id": "tt0000001", "tvdb_id": 81189},
        "content_ratings": {"results": [{"iso_3166_1": "CN", "rating": "TV-14"}]},
        "recommendations": {
            "page": 1, "total_pages": 2, "total_results": 3,
            "results": [{
                "id": 1400, "media_type": "tv", "name": "推荐剧集", "original_name": "Recommended",
                "poster_path": "/r1.jpg", "backdrop_path": "/rb1.jpg",
                "first_air_date": "2022-01-01", "vote_average": 7.1, "original_language": "zh",
                "origin_country": ["CN"], "genre_ids": [18], "overview": "推荐剧集简介",
            }],
        },
        "similar": {
            "page": 1, "total_pages": 1, "total_results": 1,
            "results": [{
                "id": 1401, "media_type": "tv", "name": "相似剧集", "original_name": "Similar",
                "poster_path": "/s.jpg", "backdrop_path": "/sb.jpg",
                "first_air_date": "2021-01-01", "vote_average": 6.8, "original_language": "zh",
                "origin_country": ["CN"], "genre_ids": [18], "overview": "相似剧集简介",
            }],
        },
    }
    if next_air:
        payload["next_episode_to_air"] = {
            "season_number": 2, "episode_number": 1, "air_date": "2099-01-01",
            "name": "未播集", "overview": "未播集",
        }
        payload["status"] = "Returning Series"
    return payload


write("detail-tv.json", detail())
write("detail-tv-next-air.json", detail(next_air=True))

write("detail-movie.json", {
    "id": 550, "title": "示例电影", "original_title": "Fixture Movie", "overview": "示例电影简介",
    "poster_path": "/movie-poster.jpg", "backdrop_path": "/movie-backdrop.jpg",
    "release_date": "2023-06-15", "vote_average": 7.9, "original_language": "en",
    "origin_country": ["US"], "genres": [{"id": 28, "name": "动作"}],
    "credits": credits(), "created_by": [],
    "translations": {"translations": [{"iso_639_1": "zh", "iso_3166_1": "CN",
                                       "data": {"overview": "示例电影简介（中文翻译版）"}}]},
    "images": {
        "posters": [{"file_path": "/mp1.jpg", "width": 680, "height": 1020,
                     "vote_average": 5.1, "vote_count": 4}],
        "backdrops": [{"file_path": "/mb1.jpg", "width": 1920, "height": 1080,
                       "vote_average": 5.0, "vote_count": 2}],
    },
    "external_ids": {"imdb_id": "tt0000550"},
    "release_dates": {"results": [{"iso_3166_1": "US",
                                   "release_dates": [{"certification": "PG-13"}]}]},
    "recommendations": {"page": 1, "total_pages": 1, "total_results": 0, "results": []},
    "similar": {"page": 1, "total_pages": 1, "total_results": 0, "results": []},
})


def season_payload(number, count, air_date, name):
    episodes = []
    for n in range(1, count + 1):
        episodes.append({
            "id": 100000 + number * 100 + n, "episode_number": n, "season_number": number,
            "name": "第 %d 集" % n, "overview": "第 %d 季第 %d 集简介" % (number, n),
            "air_date": air_date, "still_path": "/s%de%d.jpg" % (number, n),
            "vote_average": 7.0 + (n % 3) * 0.3, "runtime": 45,
        })
    return {
        "id": 2000 + number, "season_number": number, "name": name, "overview": name,
        "air_date": air_date, "poster_path": "/s%d.jpg" % number,
        "episodes": episodes, "credits": credits(), "aggregate_credits": {"cast": []},
        "images": {"posters": [{"file_path": "/sp%d.jpg" % number, "width": 680, "height": 1020,
                                "vote_average": 5.0, "vote_count": 2}]},
        "translations": {"translations": []},
    }


write("season-0.json", season_payload(0, 3, "2021-01-10", "特别篇"))
write("season-1.json", season_payload(1, 12, "2024-03-01", "第 1 季"))
write("season-2.json", season_payload(2, 10, "2025-04-05", "第 2 季"))
write("season-empty.json", {"id": 2009, "season_number": 9, "name": "第 9 季", "episodes": [],
                            "credits": {"cast": [], "crew": []}, "images": {},
                            "translations": {"translations": []}})

write("episode-s1e1.json", {
    "id": 100101, "episode_number": 1, "season_number": 1, "name": "第 1 集",
    "overview": "第 1 季第 1 集简介", "air_date": "2024-03-01", "still_path": "/s1e1.jpg",
    "vote_average": 7.3, "runtime": 45, "credits": credits(),
    "guest_stars": [{"id": 288, "name": "客串演员", "character": "客串", "profile_path": "/guest.jpg"}],
    "images": {"stills": [{"file_path": "/still1.jpg", "width": 1920, "height": 1080,
                           "vote_average": 5.0, "vote_count": 1}]},
    "translations": {"translations": []},
})

write("person.json", {
    "id": 287, "name": "示例演员", "known_for_department": "Acting",
    "biography": "示例演员传记", "profile_path": "/person.jpg",
    "combined_credits": {
        "cast": [
            {"id": 1399, "media_type": "tv", "name": "示例剧集", "character": "主角",
             "poster_path": "/tv-poster.jpg", "first_air_date": "2024-03-01",
             "vote_average": 8.2, "original_language": "zh", "origin_country": ["CN"],
             "genre_ids": [18], "overview": "示例剧集简介"},
            {"id": 550, "media_type": "movie", "title": "示例电影", "character": "配角",
             "poster_path": "/movie-poster.jpg", "release_date": "2023-06-15",
             "vote_average": 7.9, "original_language": "en", "origin_country": ["US"],
             "genre_ids": [28], "overview": "示例电影简介"},
        ],
        "crew": [
            {"id": 550, "media_type": "movie", "title": "示例电影", "job": "Writer",
             "department": "Writing", "poster_path": "/movie-poster.jpg",
             "release_date": "2023-06-15", "vote_average": 7.9, "original_language": "en",
             "origin_country": ["US"], "genre_ids": [28], "overview": "示例电影简介"},
        ],
    },
    "images": {"profiles": [{"file_path": "/profile1.jpg", "width": 300, "height": 450,
                             "vote_average": 5.0, "vote_count": 3}]},
    "translations": {"translations": []},
    "external_ids": {"imdb_id": "nm0000001"},
})

write("videos-tv.json", {"id": 1399, "results": [
    {"id": "v1", "key": "dQw4w9WgXcQ", "site": "YouTube", "name": "官方预告",
     "type": "Trailer", "official": True, "size": 1080, "iso_639_1": "zh", "iso_3166_1": "CN",
     "published_at": "2024-02-01T00:00:00.000Z"},
    {"id": "v2", "key": "abc-DEF_123", "site": "YouTube", "name": "Teaser", "type": "Teaser",
     "official": False, "size": 720, "iso_639_1": "en", "iso_3166_1": "US",
     "published_at": "2024-01-01T00:00:00.000Z"},
    {"id": "v3", "key": "bad key with spaces", "site": "YouTube", "name": "非法 key",
     "type": "Clip", "official": False, "size": 480, "iso_639_1": "en", "iso_3166_1": "US",
     "published_at": "2024-01-02T00:00:00.000Z"},
    {"id": "v4", "key": "x" * 200, "site": "YouTube", "name": "超长 key",
     "type": "Clip", "official": False, "size": 480, "iso_639_1": "en", "iso_3166_1": "US",
     "published_at": "2024-01-03T00:00:00.000Z"},
    {"id": "v5", "key": "clip123", "site": "YouTube", "name": "花絮", "type": "Featurette",
     "official": True, "size": 1080, "iso_639_1": "", "iso_3166_1": "",
     "published_at": "2024-01-04T00:00:00.000Z"},
]})


def recommendations(page, ids, prefix):
    return {"page": page, "total_pages": 2, "total_results": 4, "results": [
        {"id": i, "media_type": "tv", "name": "%s%d" % (prefix, i),
         "original_name": "%s%d" % (prefix, i),
         "poster_path": "/%s%d.jpg" % (prefix, i), "backdrop_path": "/%s%db.jpg" % (prefix, i),
         "first_air_date": "2022-01-01", "vote_average": 7.0, "original_language": "zh",
         "origin_country": ["CN"], "genre_ids": [18], "overview": "%s%d 简介" % (prefix, i)}
        for i in ids]}


write("recommendations-page1.json", recommendations(1, [1400, 1401], "R"))
write("recommendations-page2.json", recommendations(2, [1402, 1403], "R"))
write("recommendations-empty.json", {"page": 9, "total_pages": 1, "total_results": 0,
                                     "results": []})

write("error-401.json", {"status_code": 7, "success": False,
                         "status_message": "Invalid API key: You must be granted a valid key."})
write("error-500.json", {"status_code": 11, "success": False, "status_message": "Internal error."})

with open(os.path.join(BASE, "malformed.json"), "w", encoding="utf-8", newline="\n") as stream:
    stream.write('{"results": [ {"id": 1399, "name": "未闭合的 JSON"\n')

print("TMDB fixtures written to", BASE)
