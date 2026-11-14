"""CatVod 方言测试站源（方案 2 端到端 fixture）。

刻意只用标准库，并且刻意做成「CatVod 形状」：

- `class Spider(BaseSpider)` 继承宿主垫片，零参构造；
- 方法签名是 CatVod 的位置参数形态（不是宿主的 params/context）；
- init 与各方法里都有 print()，用来验证「站源输出不得污染协议帧」；
- homeContent 通过垫片 self.fetch() 访问测试服务，验证 requests 风格响应。
"""

from base.spider import Spider as BaseSpider


class Spider(BaseSpider):
    def __init__(self):
        self.extend = ""

    def init(self, extend=""):
        self.extend = str(extend or "")
        print("fixture catvod: init 里的 print 必须落到 stderr")
        self.log("fixture catvod: init")
        return {"extend": self.extend}

    def getName(self):
        return "fixture-catvod"

    def homeContent(self, filter):
        first = "分类"
        if self.extend:
            rsp = self.fetch(self.extend + "/api/echo")
            if rsp.status_code == 200:
                first = str(rsp.json().get("path") or "分类")
        print("fixture catvod: homeContent 的 print")
        return {
            "class": [{"type_id": "1", "type_name": first}],
            "filters": {},
        }

    def categoryContent(self, tid, pg, filter, extend):
        return {
            "page": int(pg),
            "pagecount": 2,
            "total": 3,
            "list": [{"vod_id": tid + "-" + str(pg), "vod_name": "分类 " + tid}],
        }

    def detailContent(self, ids):
        vid = ids[0] if ids else ""
        return {
            "list": [
                {
                    "vod_id": vid,
                    "vod_name": "详情 " + vid,
                    "vod_play_from": "line",
                    "vod_play_url": "第1集$" + vid + "-1",
                }
            ]
        }

    def searchContent(self, key, quick, pg="1"):
        return {
            "page": int(pg),
            "pagecount": 1,
            "list": [{"vod_id": "s-1", "vod_name": key or "空关键词"}],
        }

    def playerContent(self, flag, id, vipFlags):
        return {
            "parse": 0,
            "url": "http://127.0.0.1/media/" + id + ".m3u8",
            "header": {},
        }
