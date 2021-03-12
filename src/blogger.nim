import times
import logging
import jester
import uri
import os
#import io
import markdown
import strutils
import parsetoml
import sequtils

type
  FrontMatter = ref object
    createdAt: string
    categories: seq[string]
  MarkdownFile = ref object
    frontMatter: FrontMatter
    body: string ## HTML

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
  let categories = root["categories"].getElems().map(proc(elem: TomlValueRef): string = elem.getStr())
  return FrontMatter(createdAt: createdAt, categories: categories)

proc parseMarkdownFile(filePath: string): MarkdownFile = 
  var rawFrontMatter = ""
  var body = ""
  var isFrontMatterSection = false;
  for line in lines(filePath):
    if line.startsWith("==="):
      isFrontMatterSection = not isFrontMatterSection
      continue
    if isFrontMatterSection:
      rawFrontMatter.add(line)
      rawFrontMatter.add("\n")
    else:
      body.add(line)
      body.add("\n")
  let frontMatter = rawFrontMatter.parseFrontMatter()
  let bodyHtml = markdown(body)
  return MarkdownFile(frontMatter: frontMatter, body: bodyHtml)

proc generateArticleHtml(article: string): string =
  let start = cpuTime()
  let templateHtml = articleHtml()
  let markdownFile = parseMarkdownFile(appHome() / "articles" / article & ".md")
  var categoriesHtml = ""
  for category in markdownFile.frontMatter.categories:
    categoriesHtml.add("""<li class="category-list-item"><a href="/category/$1">$1</a></li>""" % [category])
  result = templateHtml
    .replace("$article-title", article)
    .replace("$article-categories", categoriesHtml)
    .replace("$article-date", markdownFile.frontMatter.createdAt)
    .replace("$article-body", markdownFile.body)
  echo "$#: Processed article.html for article: $#. (took $#ms)" %
    [now().format("yyyy-MM-dd"), article, $toInt(((cpuTime() - start) * 1000))]

proc generateListPage(category: string = ""): string =
  let start = cpuTime()
  let templateHtml = listHtml();
  var articleList = ""
  var allCategories = newSeq[string]()
  for articleFile in walkFiles(appHome() / "articles" / "*.md"):
    var isFrontMatterSection = false;
    var rawFrontMatter = ""
    for line in lines(articleFile):
      if line.startsWith("==="):
        isFrontMatterSection = not isFrontMatterSection
        continue
      if not isFrontMatterSection:
        break
      rawFrontMatter.add(line)
      rawFrontMatter.add("\n")
    let frontMatter = parseFrontMatter(rawFrontMatter)
    allCategories.add(frontMatter.categories)
    if category == "" or frontMatter.categories.contains(category):
      articleList.add("""<li><a href="/article/$1">$1</a> - $2</li>""" % [splitFile(articleFile).name, frontMatter.createdAt])
  if category != "" and articleList.len == 0:
    return ""
  var categoryStr: string
  if category == "": categoryStr = "すべて"
  else: categoryStr = category
  var allCategoriesHtml = ""
  for category in allCategories.deduplicate():
    allCategoriesHtml.add("""<li class="category-list-item"><a href="/category/$1">$1</a></li>""" % [category])
  result = templateHtml.replace("$filter-category", categoryStr)
    .replace("$all-categories", allCategoriesHtml)
    .replace("$articles", articleList)
  echo "$#: Processed list.html for category: '$#'. (took $#ms)" %
    [now().format("yyyy-MM-dd"), categoryStr, $toInt(((cpuTime() - start) * 1000))]

routes:
  get "/":
    resp generateListPage()
  get "/style.css":
    resp Http200, [("Content-Type", "text/css")], styleCss()
  get "/category/@category":
    let generated = generateListPage(@"category".decodeUrl())
    if generated == "": resp Http404
    else: resp generated
  get "/article/@article":
    try:
      resp generateArticleHtml(@"article".decodeUrl())
    except:
      let
        e = getCurrentException()
        msg = getCurrentExceptionMsg()
      echo "Error: ", repr(e), " message ", msg
      resp Http404
