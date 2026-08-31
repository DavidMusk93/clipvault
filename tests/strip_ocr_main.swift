import Foundation
import CoreGraphics

/// Compile with StripOCR.swift + ImageStoragePolicy.swift:
///   swiftc -o /tmp/strip_ocr_test -framework Vision -framework ImageIO -framework CoreGraphics \
///     ClipFlow/StripOCR.swift ClipFlow/ImageStoragePolicy.swift tests/strip_ocr_main.swift
@main
enum StripOCRStitchTests {
    static func main() {
        var fails = 0
        func run(_ name: String, _ runs: [StripOCR.Run], _ want: String) {
            let got = StripOCR.reconstruct(runs) ?? ""
            if got != want {
                FileHandle.standardError.write(Data(
                    "FAIL \(name)\n  want: \(want.debugDescription)\n   got: \(got.debugDescription)\n".utf8
                ))
                fails += 1
            } else {
                print("OK \(name)")
            }
        }
        func eq(_ name: String, _ got: String, _ want: String) {
            if got != want {
                FileHandle.standardError.write(Data(
                    "FAIL \(name)\n  want: \(want.debugDescription)\n   got: \(got.debugDescription)\n".utf8
                ))
                fails += 1
            } else {
                print("OK \(name)")
            }
        }

        // Same ink, two pages: full-width good + garbled copy. Keep the good one.
        run(
            "iou-garbled-copy",
            [
                StripOCR.Run(
                    text: "通过娱记多方调查，基本可以确认，孙宇晨小作文这一出，客观效果就是",
                    x0: 40, x1: 1160, yMid: 900, yH: 36, edgeDist: 80
                ),
                StripOCR.Run(
                    text: "通计娱记多方调查 其木可以确认 孙宝是小作文这_出 安观效里就早",
                    x0: 42, x1: 1155, yMid: 904, yH: 34, edgeDist: 8, confidence: 0.4
                ),
            ],
            "通过娱记多方调查，基本可以确认，孙宇晨小作文这一出，客观效果就是"
        )

        // 末 vs 未 twins concatenated on one line after join.
        run(
            "twin-末未",
            [
                StripOCR.Run(
                    text: "HTX4到6月的储备金证明，按8月末价格重估：",
                    x0: 40, x1: 1100, yMid: 400, yH: 36, edgeDist: 90
                ),
                StripOCR.Run(
                    text: "HTX4到6月的储备金证明，按8月未价格重估：",
                    x0: 38, x1: 1095, yMid: 402, yH: 35, edgeDist: 10
                ),
            ],
            "HTX4到6月的储备金证明，按8月末价格重估："
        )

        // Wrap leftover from overlap as its own line.
        run(
            "suffix-美元",
            [
                StripOCR.Run(
                    text: "美元。TRX 91.9亿枚，按0.34，31.2亿美元。USDT 17.65亿枚，17.7亿",
                    x0: 40, x1: 1160, yMid: 500, yH: 36
                ),
                StripOCR.Run(text: "美元。", x0: 40, x1: 120, yMid: 538, yH: 30, edgeDist: 4),
            ],
            "美元。TRX 91.9亿枚，按0.34，31.2亿美元。USDT 17.65亿枚，17.7亿美元。"
        )

        run(
            "suffix-13分钟",
            [
                StripOCR.Run(
                    text: "2026年5月3到5日三天发了200多条视频，平均不到13分钟一条。",
                    x0: 40, x1: 1160, yMid: 700, yH: 36
                ),
                StripOCR.Run(text: "13分钟一条。", x0: 40, x1: 220, yMid: 738, yH: 28, edgeDist: 3),
            ],
            "2026年5月3到5日三天发了200多条视频，平均不到13分钟一条。"
        )

        // Sequential words on one line must still concatenate.
        run(
            "same-line-concat",
            [
                StripOCR.Run(text: "BTC 21,314枚，按8万，17.0亿美元。", x0: 40, x1: 590, yMid: 200, yH: 36),
                StripOCR.Run(text: "ETH 117,175枚，按2500，2.9亿", x0: 598, x1: 1100, yMid: 201, yH: 36),
            ],
            "BTC 21,314枚，按8万，17.0亿美元。ETH 117,175枚，按2500，2.9亿"
        )

        // Two accounting lines share 枚/按/亿 — must not collapse.
        run(
            "keep-btc-trx",
            [
                StripOCR.Run(text: "BTC 21,314枚，按8万，17.0亿美元。ETH 117,175枚，按2500，2.9亿", x0: 40, x1: 1160, yMid: 200, yH: 36),
                StripOCR.Run(text: "美元。TRX 91.9亿枚，按0.34，31.2亿美元。USDT 17.65亿枚，17.7亿", x0: 40, x1: 1160, yMid: 240, yH: 36),
            ],
            "BTC 21,314枚，按8万，17.0亿美元。ETH 117,175枚，按2500，2.9亿\n美元。TRX 91.9亿枚，按0.34，31.2亿美元。USDT 17.65亿枚，17.7亿"
        )

        run(
            "wrap-了。",
            [
                StripOCR.Run(text: "这盘棋就活", x0: 40, x1: 400, yMid: 100, yH: 36),
                StripOCR.Run(text: "了。", x0: 40, x1: 90, yMid: 140, yH: 30),
                StripOCR.Run(text: "但时间已经不归他管了。", x0: 40, x1: 700, yMid: 180, yH: 36),
            ],
            "这盘棋就活了。\n但时间已经不归他管了。"
        )

        // Distinct short line after a sentence — do not swallow.
        run(
            "keep-卖不了",
            [
                StripOCR.Run(text: "所以粉丝的逻辑很朴素：账上缺26亿，卖TRX补上不就完了。", x0: 40, x1: 1100, yMid: 300, yH: 36),
                StripOCR.Run(text: "卖不了。", x0: 40, x1: 160, yMid: 350, yH: 36),
            ],
            "所以粉丝的逻辑很朴素：账上缺26亿，卖TRX补上不就完了。\n卖不了。"
        )

        eq(
            "trim-arabic-tail",
            StripOCR.trimGarbledTail("六，8月27日起诉景甜要回3000万彩礼，当晚发六千多字的《我的女友 wn ٤١Tp ٦٨ /٤١٨٠"),
            "六，8月27日起诉景甜要回3000万彩礼，当晚发六千多字的《我的女友"
        )
        eq(
            "trim-kana-tail",
            StripOCR.trimGarbledTail("新能源汽车全上，事业部扩到 200多个独立核算单位，还搞了个天空工场 ーー しりし"),
            "新能源汽车全上，事业部扩到 200多个独立核算单位，还搞了个天空工场"
        )
        eq(
            "keep-usdt-tail",
            StripOCR.trimGarbledTail("压着17.7亿USDT"),
            "压着17.7亿USDT"
        )
        eq(
            "trim-seam-dash",
            StripOCR.trimGarbledTail("追觅所谓的200多个事 -"),
            "追觅所谓的200多个事"
        )

        run(
            "stray-dash-run",
            [
                StripOCR.Run(text: "追觅所谓的200多个事", x0: 40, x1: 900, yMid: 100, yH: 36),
                StripOCR.Run(text: "-", x0: 920, x1: 940, yMid: 101, yH: 10),
            ],
            "追觅所谓的200多个事"
        )

        let twin = "热搜有保质期，26亿的窟窿没有。景甜这颗炸弹炸完，公众散场，账一分热搜有保质期，26亿的窟隆没伺。景甜这颗炸弹炸完，公众散场，账一分"
        let collapsed = StripOCR.collapseTwin(twin)
        if collapsed.contains("窟窿没有") && !collapsed.contains("窟隆没伺") && collapsed.count < twin.count {
            print("OK collapse-twin-line")
        } else {
            FileHandle.standardError.write(Data("FAIL collapse-twin-line got \(collapsed.debugDescription)\n".utf8))
            fails += 1
        }

        run(
            "garbled-second-half",
            [
                StripOCR.Run(text: "创始人从此不出来蹦跶了。", x0: 40, x1: 620, yMid: 800, yH: 36, edgeDist: 70),
                StripOCR.Run(text: "即%人从此个山來蝴哒」。", x0: 50, x1: 610, yMid: 803, yH: 34, edgeDist: 6, confidence: 0.3),
            ],
            "创始人从此不出来蹦跶了。"
        )

        if fails > 0 {
            FileHandle.standardError.write(Data("strip-ocr-stitch: \(fails) failed\n".utf8))
            exit(1)
        }
        print("strip-ocr-stitch: all passed")
    }
}
