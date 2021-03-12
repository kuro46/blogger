import tables
import algorithm
import times
import logging
import jester
import uri
import os
import markdown
import strutils
import parsetoml
import sequtils

type
  FrontMatter = ref object
    createdAt: string
    categories: seq[string]
  LazyMarkdownFile = ref object
    lastUpdated: int64 # Unix time
    sourcePath: string
    frontMatter: FrontMatter ## Must read by readFrontMatter()
    bodyHtml: string ## Must read by readBodyHtml()

var markdownFileCache {.threadvar.}: TableRef[string, LazyMarkdownFile]

proc appHome(): string = expandTilde("~/Blog/")

proc listHtml(): string =
  return readFile(appHome() / "resources/list.html")

proc articleHtml(): string =
  return readFile(appHome() / "resources/article.html")

proc styleCss(): string =
  return readFile(appHome() / "resources/style.css")

proc parseFrontMatter(raw: string): FrontMatter =
  let root = parsetoml.parseString(raw)
  let createdAt = root["created_at"].getStr()
  let categories = root["categories"].getElems().map(proc(
      elem: TomlValueRef): string = elem.getStr())
  return FrontMatter(createdAt: createdAt, categories: categories)

proc currentUnixSeconds(): int64 = getTime().toUnix()

proc newMarkdownFile(sourcePath: string): LazyMarkdownFile =
  # Init cache table
  if markdownFileCache == nil:
    markdownFileCache = newTable[string, LazyMarkdownFile]()
  let got = markdownFileCache.getOrDefault(sourcePath, nil)
  if got != nil and got.lastUpdated > currentUnixSeconds() - 300:
    # If cache found and it is fresh
    return markdownFileCache[sourcePath]
  else:
    let markdownFile = new(LazyMarkdownFile)
    markdownFile.sourcePath = sourcePath
    markdownFile.lastUpdated = currentUnixSeconds()
    markdownFileCache[sourcePath] = markdownFile
    return markdownFile

proc fillMarkdownFile(file: var LazyMarkdownFile, onlyFrontMatter: bool = false) =
  if file.bodyHtml != "" and file.frontMatter != nil:
    return
  var rawFrontMatter = ""
  var body = ""
  var isFrontMatterSection = false;
  for line in lines(file.sourcePath):
    if line.startsWith("==="):
      isFrontMatterSection = not isFrontMatterSection
      continue
    if isFrontMatterSection:
      rawFrontMatter.add(line)
      rawFrontMatter.add("\n")
    else:
      if onlyFrontMatter:
        break
      else:
        body.add(line)
        body.add("\n")
  file.frontMatter = rawFrontMatter.parseFrontMatter()
  if not onlyFrontMatter:
    file.bodyHtml = markdown(body)

proc readFrontMatter(file: var LazyMarkdownFile): FrontMatter =
  if file.frontMatter != nil: return file.frontMatter
  fillMarkdownFile(file, onlyFrontMatter = true)
  return file.frontMatter

proc readBodyHtml(file: var LazyMarkdownFile): string =
  if file.bodyHtml == "": return file.bodyHtml
  fillMarkdownFile(file)
  return file.bodyHtml

proc generateArticleHtml(article: string): string =
  let start = cpuTime()
  let templateHtml = articleHtml()
  var markdownFile = newMarkdownFile(appHome() / "articles" / article & ".md")
  markdownFile.fillMarkdownFile()
  var categoriesHtml = ""
  for category in markdownFile.frontMatter.categories:
    categoriesHtml.add("""<li class="category-list-item"><a href="/category/$1">$1</a></li>""" %
        [category])
  result = templateHtml
    .replace("$article-title", article)
    .replace("$article-categories", categoriesHtml)
    .replace("$article-date", markdownFile.frontMatter.createdAt)
    .replace("$article-body", markdownFile.bodyHtml)
  echo "$#: Processed article.html for article: $#. (took $#μs)" %
    [now().format("yyyy-MM-dd HH:mm:ss"), article, $toInt(((cpuTime() - start) * 1000000))]

proc joinString[T](s: seq[T], conv: proc(raw: T): string): string =
  result = ""
  for raw in s:
    result.add(conv(raw))

proc generateListPage(category: string = ""): string =
  let start = cpuTime()
  let templateHtml = listHtml();
  var articleList = newSeq[(string, int64)]()
  var allCategories = newSeq[string]()
  for articleFile in walkFiles(appHome() / "articles" / "*.md"):
    var markdownFile = newMarkdownFile(articleFile)
    let frontMatter = markdownFile.readFrontMatter()
    allCategories.add(frontMatter.categories)
    if category == "" or frontMatter.categories.contains(category):
      let html = """<li>$1 - <a href="/article/$2">$2</a></li>""" % [
          frontMatter.createdAt, splitFile(articleFile).name]
      articleList.add((html, frontMatter.createdAt.parse("yyyy/MM/dd").toTime().toUnix()))
  if category != "" and articleList.len == 0:
    return ""
  sort(articleList, proc(x, y: (string, int64)): int = x[1].cmp(y[1]), SortOrder.Descending)
  var categoryStr: string
  if category == "": categoryStr = "すべて"
  else: categoryStr = category
  var allCategoriesHtml = ""
  allCategories.sort()
  for category in allCategories.deduplicate(isSorted = true):
    allCategoriesHtml.add("""<li class="category-list-item"><a href="/category/$1">$1</a></li>""" %
        [category])
  result = templateHtml.replace("$filter-category", categoryStr)
    .replace("$all-categories", allCategoriesHtml)
    .replace("$articles", joinString(articleList, proc(raw: (string, int64)): string = raw[0]))
  echo "$#: Processed list.html for category: '$#'. (took $#μs)" %
    [now().format("yyyy-MM-dd HH:mm:ss"), categoryStr, $toInt(((cpuTime() -
        start) * 1000000))]

routes:
  get "/":
    resp generateListPage()
  get "/style.css":
    resp Http200, [("Content-Type", "text/css")], styleCss()
  get "/category/@category":
    let generated = generateListPage(@"category".decodeUrl())
    if generated == "": resp Http404
    else: resp generated
  get "/category/?":
    redirect "/"
  get "/article/@article":
    try:
      resp generateArticleHtml(@"article".decodeUrl())
    except:
      let
        e = getCurrentException()
        msg = getCurrentExceptionMsg()
      echo "Error: ", repr(e), " message ", msg
      resp Http404
  get "/article/?":
    redirect "/"
  get "/about/?":
    resp readFile(appHome() / "about.html")
