"""
Paper Reading Quality Check Script
Phase 4: 对论文阅读流程的产出进行自动化抽样检查

用法:
    python .agents/skills/paper-reading/scripts/quality_check.py <paper_dir>

示例:
    python .agents/skills/paper-reading/scripts/quality_check.py paper_reading/gfs_20260405_235854
"""

import sys
import re
import json
from pathlib import Path


def check_file_exists(path: Path, label: str) -> bool:
    """检查文件是否存在"""
    if path.exists():
        size = path.stat().st_size
        print(f"  [PASS] {label}: {path.name} ({size:,} bytes)")
        return True
    else:
        print(f"  [FAIL] {label}: {path.name} 不存在")
        return False


def count_headings(filepath: Path) -> list[str]:
    """统计 Markdown 文件中的标题"""
    headings = []
    for line in filepath.read_text(encoding="utf-8").splitlines():
        if line.startswith("#"):
            headings.append(line.strip())
    return headings


def count_images(filepath: Path) -> list[str]:
    """统计 Markdown 文件中的图片引用"""
    content = filepath.read_text(encoding="utf-8")
    return re.findall(r"!\[.*?\]\((.*?)\)", content)


def check_image_files_exist(paper_dir: Path, image_refs: list[str], source_file: str) -> int:
    """检查图片引用指向的文件是否实际存在"""
    issues = 0
    for ref in image_refs:
        if source_file == "translated":
            # 翻译文件中的路径是 ../markdown/images/xxx
            img_path = paper_dir / "translated" / ref
        else:
            # 原始文件中的路径是 images/xxx
            img_path = paper_dir / "markdown" / ref
        
        if not img_path.exists():
            print(f"    [WARN] 图片不存在: {ref}")
            issues += 1
    return issues


def compare_sections(original_headings: list[str], translated_headings: list[str]) -> dict:
    """对比原文和翻译的章节结构"""
    # 提取章节号（如 "# 3.1" -> "3.1"）
    def extract_section_num(heading: str) -> str:
        match = re.search(r"(\d+(?:\.\d+)*)", heading)
        return match.group(1) if match else ""
    
    orig_sections = [extract_section_num(h) for h in original_headings if extract_section_num(h)]
    trans_sections = [extract_section_num(h) for h in translated_headings if extract_section_num(h)]
    
    orig_set = set(orig_sections)
    trans_set = set(trans_sections)
    
    missing = orig_set - trans_set
    extra = trans_set - orig_set
    
    return {
        "original_count": len(original_headings),
        "translated_count": len(translated_headings),
        "original_sections": sorted(orig_sections),
        "translated_sections": sorted(trans_sections),
        "missing_in_translation": sorted(missing),
        "extra_in_translation": sorted(extra),
    }


def spot_check_paragraphs(original: Path, translated: Path, sections: list[str]) -> list[dict]:
    """抽检指定章节的段落数量是否大致匹配"""
    orig_content = original.read_text(encoding="utf-8")
    trans_content = translated.read_text(encoding="utf-8")
    
    results = []
    for section in sections:
        # 找到该章节在原文中的段落数（非空行数）
        orig_count = count_paragraphs_in_section(orig_content, section)
        trans_count = count_paragraphs_in_section(trans_content, section)
        
        ratio = trans_count / orig_count if orig_count > 0 else 0
        status = "PASS" if ratio >= 0.7 else "WARN"  # 翻译段落数应至少为原文的70%
        
        results.append({
            "section": section,
            "original_paragraphs": orig_count,
            "translated_paragraphs": trans_count,
            "ratio": f"{ratio:.1%}",
            "status": status,
        })
    
    return results


def count_paragraphs_in_section(content: str, section_num: str) -> int:
    """统计指定章节中的非空行数（粗略估计段落数）"""
    lines = content.splitlines()
    in_section = False
    paragraph_count = 0
    section_pattern = re.compile(rf"^#+\s+{re.escape(section_num)}[\.\s]")
    next_section_pattern = re.compile(r"^#+\s+\d")
    
    for line in lines:
        if section_pattern.search(line):
            in_section = True
            continue
        elif in_section and next_section_pattern.search(line):
            break
        elif in_section and line.strip() and not line.startswith("#"):
            paragraph_count += 1
    
    return paragraph_count


def check_reading_guide(guide_path: Path) -> dict:
    """检查阅读指南的结构完整性"""
    content = guide_path.read_text(encoding="utf-8")
    
    checks = {
        "has_structure_overview": "结构速览" in content or "论文结构" in content,
        "has_pass1": "第一遍" in content or "速读" in content,
        "has_pass2": "第二遍" in content or "通读" in content,
        "has_pass3": "第三遍" in content or "精读" in content,
        "has_qa": "自检" in content or "QA" in content,
        "has_summary_pass1": content.count("本遍总结") >= 1 or content.count("关键发现") >= 1,
        "has_summary_pass2": content.count("本遍总结") >= 2 or content.count("关键发现") >= 2,
        "has_summary_pass3": content.count("本遍总结") >= 3 or content.count("关键发现") >= 3,
    }
    
    return checks


def check_report(report_path: Path) -> dict:
    """检查研究报告的结构完整性"""
    content = report_path.read_text(encoding="utf-8")
    
    checks = {
        "has_basic_info": "基本信息" in content or "论文信息" in content,
        "has_background": "背景" in content or "动机" in content,
        "has_contribution": "贡献" in content or "核心" in content,
        "has_experiments": "实验" in content or "测量" in content or "结果" in content,
        "has_evaluation": "评价" in content or "优势" in content or "局限" in content,
        "word_count": len(content),
    }
    
    return checks


def main():
    if len(sys.argv) < 2:
        print("用法: python quality_check.py <paper_dir>")
        print("示例: python quality_check.py paper_reading/gfs_20260405_235854")
        sys.exit(1)
    
    paper_dir = Path(sys.argv[1])
    if not paper_dir.exists():
        print(f"[ERROR] 目录不存在: {paper_dir}")
        sys.exit(1)
    
    print("=" * 60)
    print(f"Phase 4 质量抽检报告")
    print(f"论文目录: {paper_dir}")
    print("=" * 60)
    
    issues = 0
    
    # === 1. 文件完整性检查 ===
    print("\n--- 1. 文件完整性检查 ---")
    original_md = paper_dir / "markdown" / "full.md"
    translated_md = paper_dir / "translated" / "full_cn.md"
    guide = paper_dir / "reading_guide.md"
    report = paper_dir / "report.md"
    
    for path, label in [
        (original_md, "Markdown 原文"),
        (translated_md, "中文翻译"),
        (guide, "阅读指南"),
        (report, "研究报告"),
    ]:
        if not check_file_exists(path, label):
            issues += 1
    
    # === 2. 章节结构对比 ===
    print("\n--- 2. 章节结构对比 (原文 vs 翻译) ---")
    if original_md.exists() and translated_md.exists():
        orig_headings = count_headings(original_md)
        trans_headings = count_headings(translated_md)
        comparison = compare_sections(orig_headings, trans_headings)
        
        print(f"  原文标题数: {comparison['original_count']}")
        print(f"  翻译标题数: {comparison['translated_count']}")
        
        if comparison["missing_in_translation"]:
            print(f"  [WARN] 翻译中缺少的章节号: {', '.join(comparison['missing_in_translation'])}")
            issues += len(comparison["missing_in_translation"])
        else:
            print(f"  [PASS] 所有章节号均已翻译")
        
        if comparison["extra_in_translation"]:
            print(f"  [INFO] 翻译中多出的章节号: {', '.join(comparison['extra_in_translation'])}")
    
    # === 3. 图片引用检查 ===
    print("\n--- 3. 图片引用检查 ---")
    if original_md.exists():
        orig_images = count_images(original_md)
        print(f"  原文图片引用数: {len(orig_images)}")
    
    if translated_md.exists():
        trans_images = count_images(translated_md)
        print(f"  翻译图片引用数: {len(trans_images)}")
        
        # 检查翻译中的图片路径格式
        correct_prefix = 0
        wrong_prefix = 0
        for img in trans_images:
            if img.startswith("../markdown/images/"):
                correct_prefix += 1
            else:
                wrong_prefix += 1
                print(f"    [WARN] 图片路径格式错误: {img}")
        
        if wrong_prefix == 0:
            print(f"  [PASS] 所有图片路径格式正确 (../markdown/images/...)")
        else:
            print(f"  [WARN] {wrong_prefix} 个图片路径格式不正确")
            issues += wrong_prefix
        
        # 检查图片文件是否存在
        img_issues = check_image_files_exist(paper_dir, trans_images, "translated")
        if img_issues == 0:
            print(f"  [PASS] 所有引用的图片文件均存在")
        else:
            issues += img_issues
    
    # === 4. 段落抽检 ===
    print("\n--- 4. 段落数量抽检 (随机3个章节) ---")
    if original_md.exists() and translated_md.exists():
        # 抽检几个代表性章节
        spot_sections = ["2.3", "4.1", "5.2"]
        results = spot_check_paragraphs(original_md, translated_md, spot_sections)
        
        for r in results:
            status_icon = "PASS" if r["status"] == "PASS" else "WARN"
            print(f"  [{status_icon}] S{r['section']}: 原文 {r['original_paragraphs']} 段 -> "
                  f"翻译 {r['translated_paragraphs']} 段 ({r['ratio']})")
            if r["status"] != "PASS":
                issues += 1
    
    # === 5. 阅读指南结构检查 ===
    print("\n--- 5. 阅读指南结构检查 ---")
    if guide.exists():
        guide_checks = check_reading_guide(guide)
        for key, passed in guide_checks.items():
            label = key.replace("has_", "").replace("_", " ")
            status = "PASS" if passed else "FAIL"
            print(f"  [{status}] {label}")
            if not passed:
                issues += 1
    
    # === 6. 研究报告结构检查 ===
    print("\n--- 6. 研究报告结构检查 ---")
    if report.exists():
        report_checks = check_report(report)
        word_count = report_checks.pop("word_count")
        print(f"  报告字数: {word_count:,} 字符")
        for key, passed in report_checks.items():
            label = key.replace("has_", "").replace("_", " ")
            status = "PASS" if passed else "FAIL"
            print(f"  [{status}] {label}")
            if not passed:
                issues += 1
    
    # === 总结 ===
    print("\n" + "=" * 60)
    if issues == 0:
        print(f"[RESULT] 所有抽检项通过! 共 0 个问题")
    else:
        print(f"[RESULT] 发现 {issues} 个问题，请检查上方标记为 WARN/FAIL 的项目")
    print("=" * 60)
    
    # 更新 progress.json
    progress_file = paper_dir / "progress.json"
    if progress_file.exists():
        progress = json.loads(progress_file.read_text(encoding="utf-8"))
        progress["phases"]["phase4_qa"] = "done"
        progress["qa_result"] = {
            "issues_found": issues,
            "status": "pass" if issues == 0 else "issues_found"
        }
        progress_file.write_text(json.dumps(progress, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"\nprogress.json 已更新")
    
    sys.exit(0 if issues == 0 else 1)


if __name__ == "__main__":
    main()
